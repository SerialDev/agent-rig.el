;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar agent-rig-tmux-program "tmux")
(defvar agent-rig-tmux-socket "agent-rig")

(defun agent-rig-tmux--call (&rest args)
  (unless (executable-find agent-rig-tmux-program)
    (user-error "Install tmux and make it available in Emacs exec-path"))
  (let ((default-directory temporary-file-directory)
        (process-environment (cons "LC_ALL=C" process-environment)))
    (with-temp-buffer
      (let ((status (apply #'process-file agent-rig-tmux-program nil t nil
                           "-L" agent-rig-tmux-socket "-f" "/dev/null" args)))
        (cons status (string-trim-right (buffer-string)))))))

(defun agent-rig-tmux--run (&rest args)
  (let ((result (apply #'agent-rig-tmux--call args)))
    (unless (equal (car result) 0)
      (error "tmux %s: %s" (car args) (cdr result)))
    (cdr result)))

(defun agent-rig-tmux--encode (metadata)
  (base64-encode-string (encode-coding-string (json-encode metadata) 'utf-8) t))

(defun agent-rig-tmux--decode (value)
  (let ((json-object-type 'alist)
        (json-array-type 'list)
        (json-key-type 'symbol))
    (json-read-from-string (decode-coding-string (base64-decode-string value) 'utf-8))))

(defun agent-rig-tmux-sessions ()
  (let ((result (agent-rig-tmux--call
                 "list-panes" "-a" "-F"
                 "#{session_name}\t#{pane_id}\t#{pane_dead}\t#{pane_dead_status}\t#{@agent-rig}"))
        sessions)
    (cond
     ((equal (car result) 0)
      (dolist (line (split-string (cdr result) "\n" t))
        (let* ((fields (split-string line "\t"))
               (encoded (nth 4 fields)))
          (when (and encoded (not (string-empty-p encoded)))
            (condition-case nil
                (let ((metadata (agent-rig-tmux--decode encoded)))
                  (when (and (equal (alist-get 'version metadata) 1)
                             (cl-every (lambda (key) (stringp (alist-get key metadata)))
                                       '(team seat provider directory)))
                    (push (append metadata
                                  `((session . ,(nth 0 fields))
                                    (pane . ,(nth 1 fields))
                                    (status . ,(if (equal (nth 2 fields) "1") "exited" "running"))
                                    (exit-code . ,(nth 3 fields)))) sessions)))
              (error (message "Ignoring invalid agent-rig metadata in %s" (car fields))))))))
     ((string-match-p "no server running\\|No such file or directory" (cdr result)) nil)
     (t (error "Cannot discover agents: %s" (cdr result))))
    (nreverse sessions)))

(defun agent-rig-tmux-start (metadata command)
  (let* ((session (concat "ar-" (secure-hash 'sha256 (json-encode
                         (mapcar (lambda (key) (alist-get key metadata))
                                 '(team seat directory))))))
         (directory (alist-get 'directory metadata))
         (target (concat "=" session))
         pane)
    (setq pane (agent-rig-tmux--run "new-session" "-d" "-P" "-F" "#{pane_id}"
                                   "-s" session "-c" directory
                                   "exec /bin/sleep 2147483647"))
    (condition-case err
        (progn
          (agent-rig-tmux--run "set-option" "-w" "-t" pane "remain-on-exit" "on")
          (agent-rig-tmux--run "set-option" "-p" "-t" pane "@agent-rig"
                               (agent-rig-tmux--encode metadata))
          (agent-rig-tmux--run "respawn-pane" "-k" "-t" pane "-c" directory
                               (concat "exec " (mapconcat #'shell-quote-argument command " ")))
          session)
      (error
       (ignore-errors (agent-rig-tmux--run "kill-session" "-t" target))
       (signal (car err) (cdr err))))))

(defun agent-rig-tmux-paste (session text)
  (unless (and (stringp text) (not (string-empty-p text)))
    (user-error "Message is empty"))
  (when (string-match-p "[\x00-\x08\x0b-\x1f\x7f]" text)
    (user-error "Message contains terminal control characters"))
  (unless (equal (alist-get 'status session) "running")
    (user-error "Agent has exited"))
  (let* ((pane (alist-get 'pane session))
         (bracketed (agent-rig-tmux--run "display-message" "-p" "-t" pane "#{bracket_paste_flag}")))
    (unless (equal bracketed "1")
      (user-error "Agent is not accepting bracketed paste; open its terminal and finish startup"))
    (let* ((file (make-temp-file "agent-rig-prompt-"))
           (buffer-name (file-name-nondirectory file))
           (coding-system-for-write 'utf-8-unix))
      (unwind-protect
          (progn
            (write-region text nil file nil 'silent)
            (agent-rig-tmux--run "load-buffer" "-b" buffer-name file)
            (apply #'agent-rig-tmux--run
                   (append '("paste-buffer" "-d" "-p" "-r")
                           (when (string-match-p "^paste-buffer .*\\[-[a-zA-Z]*S"
                                                 (agent-rig-tmux--run "list-commands"))
                             '("-S"))
                           (list "-b" buffer-name "-t" pane))))
        (ignore-errors (agent-rig-tmux--run "delete-buffer" "-b" buffer-name))
        (delete-file file)))))

(provide 'agent-rig-tmux)
