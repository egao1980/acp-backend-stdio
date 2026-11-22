(in-package #:acp-backend-stdio/tests)

;;; Framing: one JSON-RPC message per line. The test writes raw lines to
;;; SERVE-ACP-AGENT and reads what it writes back, line by line.

(defun %echo-line (id params-json)
  (format nil "{\"jsonrpc\":\"2.0\",\"id\":~a,\"method\":\"_cl-stack.test/echo\",\"params\":~a}"
          id params-json))

(defun %echoed (message key)
  (let ((r (and (hash-table-p message) (gethash "result" message))))
    (and (hash-table-p r) (hash-table-p (gethash "echo" r))
         (gethash key (gethash "echo" r)))))

(deftest framing-initialize-is-one-line
  (with-raw-agent (raw)
    (let ((m (raw-initialize raw)))
      (ok (hash-table-p m))
      (ok (eql 1 (response-id m)))
      (ok (equal "2.0" (gethash "jsonrpc" m)))
      (ok (eql 1 (gethash "protocolVersion" (gethash "result" m)))))))

(deftest framing-embedded-newlines-are-escaped
  (with-raw-agent (raw)
    (raw-initialize raw)
    ;; "a<LF>b<CR><LF>c<U+2028>d" in JSON escapes, on one input line
    (raw-send raw (%echo-line 2 "{\"s\":\"a\\nb\\r\\nc\\u2028d\"}"))
    (let ((line (raw-line raw)))
      (ok (stringp line) "the answer is one line")
      (ok (and line (not (find #\Return line))) "no raw CR inside the message")
      (let ((m (and line (json line))))
        (ok (eql 2 (response-id m)))
        (ok (equal (format nil "a~cb~c~cc~cd" #\Newline #\Return #\Newline (code-char #x2028))
                   (%echoed m "s"))
            "the string survives exactly")))
    (ok (null (raw-line raw 0.5)) "nothing else was written (no stray line from the newline)")))

(deftest framing-crlf-line-ends-are-accepted
  (with-raw-agent (raw)
    (raw-send raw (format nil "~a~c" *raw-initialize* #\Return))
    (ok (eql 1 (response-id (raw-message raw))))))

(deftest framing-blank-lines-are-ignored
  (with-raw-agent (raw)
    (raw-send raw "")
    (raw-send raw "   ")
    (let ((m (raw-initialize raw)))
      (ok (eql 1 (response-id m)) "the first line written answers initialize"))))

(deftest framing-invalid-json-is-a-parse-error-and-serving-goes-on
  ;; rpc-backend-stdio#14: in peer mode the reader answers these (0.3.1)
  (with-raw-agent (raw)
    (raw-initialize raw)
    (raw-send raw "this is not json")
    (let ((m (raw-message raw)))
      (ok (eql -32700 (error-code m)) (d m))
      (ok (and (hash-table-p m) (eq :null (gethash "id" m :missing))) "\"id\": null"))
    (raw-send raw "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":")
    (ok (eql -32700 (error-code (raw-message raw))) "truncated JSON")
    (raw-send raw "42")
    (ok (eql -32600 (error-code (raw-message raw))) "not an object")
    (raw-send raw (%echo-line 3 "{\"k\":\"v\"}"))
    (let ((m (raw-message raw)))
      (ok (eql 3 (response-id m)) "still serving")
      (ok (equal "v" (%echoed m "k"))))))

(deftest framing-a-final-line-without-newline-is-handled
  (with-raw-agent (raw)
    (raw-initialize raw)
    (raw-send raw (%echo-line 2 "{\"last\":true}") :newline nil)
    (raw-close-input raw)
    (let ((m (raw-message raw)))
      (ok (eql 2 (response-id m)) "the unterminated last line is a message")
      (ok (eq t (%echoed m "last"))))
    (ok (await (raw-serve raw) 10) "SERVE-ACP-AGENT returns at EOF")
    (ok (null (outcome-condition (raw-serve raw))) (d (outcome-condition (raw-serve raw))))))

(deftest framing-a-partial-line-at-eof-ends-serving-cleanly
  (with-raw-agent (raw)
    (raw-initialize raw)
    (raw-send raw "{\"jsonrpc\":\"2.0\",\"id\":7,\"meth" :newline nil)
    (raw-close-input raw)
    (ok (await (raw-serve raw) 10) "no hang on a cut-off message")
    (ok (null (outcome-condition (raw-serve raw))) (d (outcome-condition (raw-serve raw))))
    (let ((m (raw-message raw 2)))
      (ok (or (null m) (eql -32700 (error-code m)))
          "the fragment is answered -32700 or not at all, never as a request"))))

(deftest framing-every-line-written-is-a-json-rpc-message
  (with-raw-agent (raw)
    (raw-initialize raw)
    (raw-send raw "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"session/new\",\"params\":{\"cwd\":\"/w\",\"mcpServers\":[]}}")
    (let* ((m (raw-message raw))
           (sid (gethash "sessionId" (gethash "result" m))))
      (ok (stringp sid))
      ;; "burst": 200 session/update notifications, then the response
      (raw-send raw (format nil "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"session/prompt\",\"params\":{\"sessionId\":~s,\"prompt\":[{\"type\":\"text\",\"text\":\"burst\"}]}}" sid))
      (let ((lines (loop for line = (raw-line raw)
                         while line
                         collect line
                         until (eql 3 (response-id (json line))))))
        (ok (= 201 (length lines)) (d (length lines)))
        (ok (every (lambda (l) (let ((v (json l))) (and (hash-table-p v)
                                                         (equal "2.0" (gethash "jsonrpc" v)))))
                   lines))
        (ok (equal (loop for i below 200 collect (princ-to-string i))
                   (loop for l in (butlast lines)
                         collect (gethash "text" (gethash "content" (gethash "update" (gethash "params" (json l)))))))
            "in order, all before the response")))))

(defun %big-text (n)
  "N characters with newlines, quotes and non-ASCII spread through."
  (let ((s (make-string n)))
    (dotimes (i n s)
      (setf (char s i) (case (mod i 997)
                         (0 #\Newline) (1 #\") (2 #\\) (3 (code-char #xE9)) (4 (code-char #x65E5))
                         (t (code-char (+ 97 (mod i 26)))))))))

(deftest framing-a-message-over-one-mebibyte
  (with-pair (p)
    (session-of p)
    (let* ((big (%big-text (+ (* 1024 1024) 300000)))
           (r (multiple-value-list
               (call-within 60 (lambda () (acp:acp-call-ext (pair-ra p) "_cl-stack.test/echo"
                                                            (js "text" big)))))))
      (ok (third r) "within 60 s")
      (ok (null (second r)) (d (second r)))
      (let ((echo (and (hash-table-p (first r)) (gethash "echo" (first r)))))
        (ok (and (hash-table-p echo) (equal big (gethash "text" echo)))
            "1.3 MiB each way, exact")))))
