;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar agent-rig-codex-socket nil)

(defun agent-rig-codex--socket ()
  (or agent-rig-codex-socket
      (expand-file-name "app-server-control/app-server-control.sock"
                        (or (getenv "CODEX_HOME") "~/.codex/"))))

(defun agent-rig-codex--connect (opened received failed)
  (unless (require 'websocket nil t)
    (user-error "Install the Emacs websocket package for Codex native activity"))
  (let* ((url "ws://localhost/")
         (key (websocket-genkey))
         (connection (make-network-process :name "agent-rig-codex" :buffer nil
                                           :family 'local :service (agent-rig-codex--socket)
                                           :coding 'binary :noquery t))
         (socket (websocket-inner-create
                  :conn connection :url url :accept-string (websocket-calculate-accept key)
                  :on-open opened :on-message received
                  :on-close (lambda (_) (funcall failed "Codex connection closed"))
                  :on-error (lambda (_socket _kind error) (funcall failed (format "%s" error))))))
    (process-put connection :websocket socket)
    (set-process-filter connection
                        (lambda (_process output) (websocket-outer-filter socket output)))
    (set-process-sentinel connection
                          (lambda (process event)
                            (when (memq (process-status process) '(closed failed exit signal))
                              (funcall failed (string-trim event)))))
    (websocket-ensure-handshake url connection key nil nil nil nil)
    socket))

(defun agent-rig-codex--client (ready failed)
  (let ((pending (make-hash-table :test #'eql)) (serial 0) socket timer stopped)
    (cl-labels
        ((cancel ()
           (unless stopped
             (setq stopped t)
             (when (timerp timer) (cancel-timer timer))
             (clrhash pending)
             (when socket (ignore-errors (websocket-close socket)))))
         (fail (message)
           (unless stopped (cancel) (funcall failed message)))
         (request (method params callback)
           (unless (member method '("initialize" "thread/read" "thread/list"
                                    "thread/loaded/list" "thread/items/list"))
             (error "Agent Rig only reads Codex activity"))
           (unless stopped
             (cl-incf serial)
             (puthash serial callback pending)
             (websocket-send-text socket
                                  (encode-coding-string
                                   (json-encode `((id . ,serial) (method . ,method) (params . ,params))) 'utf-8)))))
      (condition-case err
          (progn
            (setq socket
                  (agent-rig-codex--connect
                   (lambda (connection)
                     (setq socket connection)
                     (request "initialize" '((clientInfo . ((name . "agent-rig") (version . "0.1"))))
                              (lambda (error _result)
                                (if error (fail error) (funcall ready #'request #'cancel)))))
                   (lambda (_connection frame)
                     (unless stopped
                       (condition-case err
                           (let* ((json-object-type 'alist) (json-array-type 'list)
                                  (json-key-type 'symbol) (json-null nil)
                                  (message (json-read-from-string (websocket-frame-text frame)))
                                  (id (alist-get 'id message))
                                  (callback (gethash id pending)))
                             (when callback
                               (remhash id pending)
                               (funcall callback
                                        (when (alist-get 'error message)
                                          (or (alist-get 'message (alist-get 'error message)) "Codex request failed"))
                                        (alist-get 'result message))))
                         (error (fail (error-message-string err))))))
                   #'fail))
            (unless stopped
              (setq timer (run-at-time 10 nil (lambda () (fail "Codex activity request timed out"))))))
        (error (fail (error-message-string err))))
      #'cancel)))

(defun agent-rig-codex--parent (thread)
  (or (alist-get 'parentThreadId thread)
      (let ((source (alist-get 'source thread)))
        (when (listp source)
          (let ((subagent (alist-get 'subAgent source)))
            (when (listp subagent)
              (alist-get 'parent_thread_id (alist-get 'thread_spawn subagent))))))))

(defun agent-rig-codex--descendants (identity threads)
  (let ((parents (list identity)) (seen (list identity)) found)
    (while parents
      (let ((parent (pop parents)))
        (dolist (thread threads)
          (let ((id (alist-get 'id thread)))
            (when (and (stringp id) (equal parent (agent-rig-codex--parent thread))
                       (not (member id seen)))
              (push id seen) (push id parents) (push thread found))))))
    (nreverse found)))

(defun agent-rig-codex--status (thread)
  (let* ((status (alist-get 'status thread))
         (kind (alist-get 'type status))
         (flags (alist-get 'activeFlags status)))
    (concat (or kind "unknown")
            (when flags (concat " (" (mapconcat #'identity flags ", ") ")")))))

(defun agent-rig-codex--tools (entries)
  (let (lines)
    (dolist (entry entries)
      (let* ((item (alist-get 'item entry)) (kind (alist-get 'type item)))
        (when (member kind '("commandExecution" "mcpToolCall" "dynamicToolCall" "fileChange" "collabAgentToolCall"))
          (push (format "%s · %s · %s" kind (or (alist-get 'status item) "unknown")
                        (replace-regexp-in-string
                         "[\n\r\t]+" " "
                         (or (alist-get 'command item) (alist-get 'tool item) (alist-get 'id item) ""))) lines))))
    (if lines (mapconcat #'identity (nreverse lines) "\n") "No tools in the ten most recent items.")))

(defun agent-rig-codex--children (request identity callback)
  (let (threads cursors)
    (cl-labels
        ((page (cursor)
           (funcall request "thread/list"
                    (append '((limit . 100) (sourceKinds . ["subAgentThreadSpawn"]) (useStateDbOnly . t))
                            (when cursor `((cursor . ,cursor))))
                    (lambda (error result)
                      (if error (funcall callback (concat "Unavailable: " error))
                        (setq threads (append threads (alist-get 'data result)))
                        (let ((next (alist-get 'nextCursor result)))
                          (cond
                           ((null next)
                            (let* ((descendants (agent-rig-codex--descendants identity threads))
                                   (loaded (cl-remove-if
                                            (lambda (thread) (equal (agent-rig-codex--status thread) "notLoaded"))
                                            descendants)))
                              (funcall callback
                                       (if loaded
                                           (mapconcat
                                            (lambda (child)
                                              (format "%s [%s] · %s"
                                                      (or (alist-get 'agentNickname child) (alist-get 'id child))
                                                      (or (alist-get 'agentRole child) "agent")
                                                      (agent-rig-codex--status child))) loaded "\n")
                                         "No loaded descendant agents."))))
                           ((or (member next cursors) (>= (length threads) 1000))
                            (funcall callback "Unavailable: child inventory exceeded its bounded snapshot"))
                           (t (push next cursors) (page next)))))))))
      (page nil))))

(defun agent-rig-codex--snapshot-details (request cancel root callback)
  (let ((remaining 2) children items)
    (cl-labels ((done ()
                 (cl-decf remaining)
                 (when (= remaining 0)
                   (funcall cancel)
                   (funcall callback nil `((native . ,(agent-rig-codex--status root))
                                           (subagents . ,children) (tools . ,items))))))
      (agent-rig-codex--children request (alist-get 'id root)
                                (lambda (value) (setq children value) (done)))
      (funcall request "thread/items/list"
               `((threadId . ,(alist-get 'id root)) (limit . 10) (sortDirection . "desc"))
               (lambda (error result)
                 (setq items (if error (concat "Unavailable: " error)
                               (agent-rig-codex--tools (alist-get 'data result))))
                 (done))))))

(defun agent-rig-codex-snapshot (identity directory callback)
  (agent-rig-codex--client
   (lambda (request cancel)
     (funcall request "thread/read" `((threadId . ,identity) (includeTurns . :json-false))
              (lambda (error result)
                (let ((root (alist-get 'thread result)))
                  (cond
                   (error (funcall cancel) (funcall callback error nil))
                   ((not (and (equal identity (alist-get 'id root))
                              (stringp (alist-get 'cwd root))
                              (equal (file-truename (directory-file-name directory))
                                     (file-truename (directory-file-name (alist-get 'cwd root))))))
                    (funcall cancel) (funcall callback "Recorded conversation does not match this project" nil))
                   (t (agent-rig-codex--snapshot-details request cancel root callback)))))))
   (lambda (error) (funcall callback error nil))))

(provide 'agent-rig-codex)
