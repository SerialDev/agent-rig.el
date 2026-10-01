;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar agent-rig-claude-observe-subagents t)
(defvar agent-rig-claude-observer-directory
  (expand-file-name "agent-rig/observations/" user-emacs-directory))
(defconst agent-rig-claude--events '("SessionStart" "SessionEnd" "SubagentStart" "SubagentStop"))

(defun agent-rig-claude--write (file value)
  (let ((temporary (make-temp-file (concat file ".")))
        (coding-system-for-write 'utf-8-unix))
    (unwind-protect
        (progn
          (set-file-modes temporary #o600)
          (write-region (json-encode value) nil temporary nil 'silent)
          (rename-file temporary file t))
      (when (file-exists-p temporary) (delete-file temporary)))))

(defun agent-rig-claude--event (directory input)
  (let* ((event (alist-get 'hook_event_name input))
         (session (alist-get 'session_id input))
         (agent (alist-get 'agent_id input))
         (role (alist-get 'agent_type input)))
    (unless (and (member event agent-rig-claude--events)
                 (stringp session) (string-match-p "\\`[A-Za-z0-9_-]+\\'" session)
                 (< (length session) 200)
                 (or (member event '("SessionStart" "SessionEnd"))
                     (and (stringp agent) (< (length agent) 200)
                          (string-match-p "\\`[A-Za-z0-9_-]+\\'" agent))))
      (error "Unsupported observation"))
    (let* ((identity (if (member event '("SessionStart" "SessionEnd")) "session" agent))
           (file (expand-file-name (concat (secure-hash 'sha256 (concat session ":" (if (member event '("SessionStart" "SessionEnd")) "root:" "agent:") identity)) ".json") directory)))
      (agent-rig-claude--write
       file `((version . 1) (session . ,session) (agent . ,identity) (event . ,event)
              (role . ,(when (stringp role)
                         (replace-regexp-in-string "[\x00-\x1f\x7f]" " " (substring role 0 (min 256 (length role))))))
              (observed-at . ,(float-time)))))))

(defun agent-rig-claude-hook (directory)
  (condition-case nil
      (with-temp-buffer
        (condition-case nil
            (while t
              (insert (read-from-minibuffer "") "\n")
              (when (> (buffer-size) 4194304) (error "Observation input too large")))
          (end-of-file nil))
        (goto-char (point-min))
        (let ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol))
          (agent-rig-claude--event directory (json-read))))
    (error nil)))

(defun agent-rig-claude-prepare (metadata command)
  (if (not (and agent-rig-claude-observe-subagents
                (equal (alist-get 'provider metadata) "claude-code")))
      (cons (assq-delete-all 'observer (copy-tree metadata)) command)
    (let* ((base agent-rig-claude-observer-directory)
           (emacs (expand-file-name invocation-name invocation-directory))
           (library (locate-library "agent-rig-claude"))
           root)
      (unless (and (file-executable-p emacs) library)
        (user-error "Cannot locate the Emacs subagent observer"))
      (unless (file-directory-p base)
        (make-directory base t)
        (set-file-modes base #o700))
      (setq root (make-temp-file (expand-file-name "run-" base) t))
      (set-file-modes root #o700)
      (condition-case err
          (let* ((plugin (expand-file-name "plugin/" root))
                 (events (expand-file-name "events/" root))
                 (hook-command (mapconcat #'shell-quote-argument
                                          (list emacs "--batch" "-Q" "-l" library "--eval"
                                                (prin1-to-string (list 'agent-rig-claude-hook events))) " ")))
            (make-directory (expand-file-name ".claude-plugin/" plugin) t)
            (make-directory (expand-file-name "hooks/" plugin) t)
            (make-directory events t)
            (agent-rig-claude--write (expand-file-name ".claude-plugin/plugin.json" plugin)
                                    '((name . "agent-rig-observer") (version . "0.1.0")))
            (agent-rig-claude--write
             (expand-file-name "hooks/hooks.json" plugin)
             `((hooks . ,(mapcar
                          (lambda (event)
                            (cons (intern event)
                                  (vector `((hooks . ,(vector `((type . "command") (command . ,hook-command) (timeout . 5))))))))
                          agent-rig-claude--events))))
            (cons (cons (cons 'observer (file-name-nondirectory (directory-file-name root)))
                        (assq-delete-all 'observer (copy-tree metadata)))
                  (append command (list "--plugin-dir" plugin))))
        (error (delete-directory root t) (signal (car err) (cdr err)))))))

(defun agent-rig-claude--directory (session)
  (let ((observer (alist-get 'observer session)))
    (when (and (stringp observer) (string-match-p "\\`run-[A-Za-z0-9_-]+\\'" observer))
      (let ((directory (expand-file-name observer agent-rig-claude-observer-directory)))
        (when (file-in-directory-p directory agent-rig-claude-observer-directory)
          directory)))))

(defun agent-rig-claude-cleanup (session)
  (let ((directory (agent-rig-claude--directory session)))
    (when (and directory (file-directory-p directory)) (delete-directory directory t))))

(defun agent-rig-claude-subagents (session native)
  (let ((directory (agent-rig-claude--directory session))
        (identity (alist-get 'sessionId native)))
    (cond
     ((not directory) "Unavailable: this seat has no subagent observer.")
     ((not identity) "Unavailable: current native session identity could not be verified.")
     (t
      (condition-case nil
          (let ((files (directory-files (expand-file-name "events/" directory) t "\\.json\\'")) records marker)
            (when (> (length files) 1000) (error "Observation limit exceeded"))
            (dolist (file files)
              (when (> (file-attribute-size (file-attributes file)) 16384) (error "Invalid observation"))
              (let* ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol) (json-null nil)
                     (record (json-read-file file)))
                (when (and (equal (alist-get 'version record) 1) (equal identity (alist-get 'session record)))
                  (if (member (alist-get 'event record) '("SessionStart" "SessionEnd")) (setq marker record)
                    (push record records)))))
            (unless (equal (alist-get 'event marker) "SessionStart") (error "Observer has not reported session start"))
            (setq records (sort records (lambda (a b) (> (alist-get 'observed-at a) (alist-get 'observed-at b)))))
            (if (null records) "Observer connected; no subagent events yet."
              (concat
               "Observed lifecycle (most recent first):\n"
               (mapconcat
                (lambda (record)
                  (format "%s [%s] · %s · %s"
                          (alist-get 'agent record) (or (alist-get 'role record) "agent")
                          (pcase (alist-get 'event record)
                            ("SubagentStart" "start observed")
                            ("SubagentStop" "stop observed")
                            (_ "unknown event"))
                          (format-time-string "%H:%M:%S" (seconds-to-time (alist-get 'observed-at record)))))
                records "\n"))))
        (error "Unavailable: observer has not reported this session or its records are unreadable."))))))

(provide 'agent-rig-claude)
