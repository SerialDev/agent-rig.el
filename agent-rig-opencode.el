;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'url-util)

(defun agent-rig-opencode--ports (text)
  (let (ports)
    (dolist (line (split-string text "\n" t))
      (when (string-match "\\`n127\\.0\\.0\\.1:\\([0-9]+\\)\\'" line)
        (let ((port (string-to-number (match-string 1 line))))
          (when (and (> port 0) (< port 65536)) (cl-pushnew port ports)))))
    (nreverse ports)))

(defun agent-rig-opencode--status (identity statuses)
  (let* ((status (cdr (assoc identity statuses)))
         (kind (cdr (assoc "type" status))))
    (if (null status) "idle"
      (if (equal kind "retry")
          (format "retry %s · %s" (cdr (assoc "attempt" status)) (cdr (assoc "message" status)))
        (or kind "unknown")))))

(defun agent-rig-opencode--tools (messages)
  (let (lines)
    (dolist (message messages)
      (dolist (part (append (cdr (assoc "parts" message)) nil))
        (when (equal (cdr (assoc "type" part)) "tool")
          (let ((state (cdr (assoc "state" part))))
            (push (format "%s · %s · %s" (cdr (assoc "tool" part))
                          (or (cdr (assoc "status" state)) "unknown")
                          (replace-regexp-in-string "[\n\r\t]+" " "
                                                    (or (cdr (assoc "title" state)) ""))) lines)))))
    (if lines (mapconcat #'identity (nreverse lines) "\n") "No tools in the ten most recent messages.")))

(defun agent-rig-opencode--children (identity directory children statuses)
  (let (lines)
    (dolist (child children)
      (when (equal identity (cdr (assoc "parentID" child)))
        (let ((id (cdr (assoc "id" child))) (cwd (cdr (assoc "directory" child))))
          (push (format "%s [%s] · %s"
                        (or (cdr (assoc "title" child)) "agent") id
                        (if (and (stringp cwd)
                                 (equal (file-truename (directory-file-name directory))
                                        (file-truename (directory-file-name cwd))))
                            (agent-rig-opencode--status id statuses)
                          "unavailable (different directory)")) lines))))
    (if lines (concat "Direct child sessions:\n" (mapconcat #'identity (nreverse lines) "\n"))
      "No direct child sessions.")))

(defun agent-rig-opencode-snapshot (session callback)
  (let ((pid (alist-get 'pid session)) (identity (alist-get 'conversation session))
        (directory (alist-get 'directory session)) process timer stopped)
    (cl-labels
        ((cancel ()
           (unless stopped
             (setq stopped t)
             (when (timerp timer) (cancel-timer timer))
             (when (and process (process-live-p process)) (delete-process process))))
         (finish (error result)
           (unless stopped (cancel) (funcall callback error result)))
         (run (command input completed)
           (let ((buffer (generate-new-buffer " *rig opencode probe*")))
             (condition-case err
                 (progn
                   (setq process
                         (make-process
                          :name "rig-opencode" :buffer buffer :command command :noquery t :connection-type 'pipe
                          :sentinel
                          (lambda (child _event)
                            (when (memq (process-status child) '(exit signal))
                              (unwind-protect
                                  (unless stopped
                                    (let ((text (with-current-buffer buffer (buffer-string))))
                                      (setq process nil)
                                      (condition-case err
                                          (funcall completed (unless (= (process-exit-status child) 0) "Native probe failed") text)
                                        (error (finish (error-message-string err) nil)))))
                                (kill-buffer buffer))))))
                   (when input (process-send-string process input) (process-send-eof process)))
               (error (kill-buffer buffer) (finish (error-message-string err) nil)))))
         (get (port route completed)
           (let* ((password (getenv "OPENCODE_SERVER_PASSWORD"))
                  (authorization (when (and password (not (string-empty-p password)))
                                   (base64-encode-string
                                    (encode-coding-string
                                     (concat (or (getenv "OPENCODE_SERVER_USERNAME") "opencode") ":" password) 'utf-8) t)))
                  (url (format "http://127.0.0.1:%d%s?directory=%s%s" port route
                               (url-hexify-string (directory-file-name directory))
                               (if (string-suffix-p "/message" route) "&limit=10" ""))))
             (run (list "curl" "--disable" "--silent" "--show-error" "--fail" "--noproxy" "*"
                        "--proto" "=http" "--max-time" "5" "--max-filesize" "1048576"
                        "--config" "-" "--url" url)
                  (if authorization (format "header = \"Authorization: Basic %s\"\n" authorization) "\n")
                  (lambda (error text)
                    (if error (funcall completed error nil)
                      (let* ((json-object-type 'alist) (json-array-type 'vector) (json-key-type 'string) (json-null :null)
                             (parsed (condition-case nil (cons nil (json-read-from-string text))
                                       (error (cons "Invalid native response" nil)))))
                        (funcall completed (car parsed) (cdr parsed))))))))
         (snapshot (port)
           (get port (concat "/session/" identity)
                (lambda (error root)
                  (if error (finish error nil)
                    (if (not (and (equal identity (cdr (assoc "id" root)))
                                  (stringp (cdr (assoc "directory" root)))
                                  (equal (file-truename (directory-file-name directory))
                                         (file-truename (directory-file-name (cdr (assoc "directory" root)))))))
                        (finish "Recorded conversation does not match this project" nil)
                      (get port "/session/status"
                           (lambda (error statuses)
                             (if (or error (not (listp statuses))) (finish (or error "Invalid native status map") nil)
                               (get port (concat "/session/" identity "/children")
                                    (lambda (error children)
                                      (if (or error (not (vectorp children))) (finish (or error "Invalid native child list") nil)
                                        (get port (concat "/session/" identity "/message")
                                             (lambda (error messages)
                                               (finish nil
                                                       `((native . ,(agent-rig-opencode--status identity statuses))
                                                         (subagents . ,(agent-rig-opencode--children identity directory (append children nil) statuses))
                                                         (tools . ,(if (or error (not (vectorp messages)))
                                                                     (concat "Unavailable: " (or error "invalid native message list"))
                                                                   (agent-rig-opencode--tools (append messages nil)))))))))))))))))))
         (discover (ports)
           (if (null ports)
               (finish "No OpenCode API on this pane PID; new default seats enable loopback HTTP" nil)
             (get (car ports) "/global/health"
                  (lambda (error health)
                    (if (and (not error) (eq (cdr (assoc "healthy" health)) t)
                             (stringp (cdr (assoc "version" health))))
                        (snapshot (car ports))
                      (discover (cdr ports))))))))
      (if (not (and (equal (alist-get 'status session) "running")
                    (stringp pid) (> (string-to-number pid) 0) (string-match-p "\\`[0-9]+\\'" pid)
                    (stringp identity) (string-match-p "\\`[A-Za-z0-9_-]+\\'" identity)))
          (finish "A live pane PID and exact OpenCode conversation ID are required" nil)
        (setq timer (run-at-time 10 nil (lambda () (finish "OpenCode activity request timed out" nil))))
        (run (list "lsof" "-nP" "-a" "-p" pid "-iTCP" "-sTCP:LISTEN" "-Fn") nil
             (lambda (_error text) (discover (agent-rig-opencode--ports text)))))
      #'cancel)))

(provide 'agent-rig-opencode)
