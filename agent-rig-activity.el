;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'agent-rig-codex)

(defvar-local agent-rig-activity--generation nil)
(defvar-local agent-rig-activity--timer nil)
(defvar-local agent-rig-activity--native-cancel nil)
(defvar-local agent-rig-activity--started 0)
(defvar-local agent-rig-activity--processes nil)
(defvar-local agent-rig-activity--session nil)
(defvar-local agent-rig-activity--results nil)

(defun agent-rig-activity--native-record (session)
  (when (and (equal (alist-get 'provider session) "claude-code")
             (equal (alist-get 'status session) "running")
             (stringp (alist-get 'pid session))
             (string-match-p "\\`[0-9]+\\'" (alist-get 'pid session)))
    (condition-case nil
        (let* ((pid (string-to-number (alist-get 'pid session)))
               (file (expand-file-name (format "sessions/%s.json" pid)
                                       (or (getenv "CLAUDE_CONFIG_DIR") "~/.claude/")))
               (size (file-attribute-size (file-attributes file)))
               (json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol)
               (record (when (and size (< size 65536)) (json-read-file file)))
               (start (alist-get 'start (process-attributes pid)))
               (reported (alist-get 'startedAt record))
               (status (alist-get 'status record)))
          (when (and (equal pid (alist-get 'pid record))
                     start (numberp reported)
                     (>= reported (* 1000 (float-time start)))
                     (<= reported (* 1000 (float-time)))
                     (equal (file-truename (directory-file-name (alist-get 'directory session)))
                            (file-truename (directory-file-name (alist-get 'cwd record))))
                     (member status '("idle" "busy" "waiting" "shell")))
            record))
      (error nil))))

(defun agent-rig-activity--descendants (root text)
  (let ((parents (list (format "%s" root))) rows found)
    (dolist (line (split-string text "\n" t))
      (when (string-match "^[ \t]*\\([0-9]+\\)[ \t]+\\([0-9]+\\)[ \t]+\\(.*\\)$" line)
        (push (list (match-string 1 line) (match-string 2 line) (match-string 3 line)) rows)))
    (while parents
      (let ((parent (pop parents)))
        (dolist (row rows)
          (when (and (equal (cadr row) parent) (not (member (car row) found)))
            (push (car row) found)
            (push (car row) parents)))))
    (cl-remove-if-not (lambda (row) (member (car row) found)) (nreverse rows))))

(defun agent-rig-activity--claude-status (pid text)
  (let* ((json-object-type 'alist) (json-array-type 'list) (json-key-type 'symbol)
         (sessions (json-read-from-string text))
         (session (cl-find (format "%s" pid) sessions
                          :key (lambda (item) (format "%s" (alist-get 'pid item))) :test #'equal)))
    (if session (format "%s" (or (alist-get 'status session) "unknown")) "unavailable (PID not reported)")))

(defun agent-rig-activity--render ()
  (let ((inhibit-read-only t)
        (position (point))
        (session agent-rig-activity--session))
    (erase-buffer)
    (insert (propertize "AGENT RIG / ACTIVITY\n\n" 'face 'agent-rig-title)
            (format "%s/%s [%s]\nProcess: %s   PID: %s   Command: %s\n"
                    (alist-get 'team session) (alist-get 'seat session) (alist-get 'provider session)
                    (alist-get 'status session) (or (alist-get 'pid session) "unknown")
                    (or (alist-get 'command session) "unknown"))
            (format "Snapshot: %s   [g] refresh\n"
                    (format-time-string "%H:%M:%S" (seconds-to-time agent-rig-activity--started)))
            (format "Native activity: %s\n" (or (alist-get 'native agent-rig-activity--results) "unavailable"))
            (if (equal (alist-get 'provider session) "codex")
                (format "Recorded conversation: %s\n" (or (alist-get 'conversation session) "none; press i to record its exact ID"))
              "")
            (propertize "\nNATIVE SUBAGENTS\n" 'face 'agent-rig-section)
            (or (alist-get 'subagents agent-rig-activity--results) "Unavailable from this provider's process inventory.")
            "\n"
            (if (alist-get 'tools agent-rig-activity--results)
                (concat (propertize "\nRECENT NATIVE TOOLS\n" 'face 'agent-rig-section)
                        (alist-get 'tools agent-rig-activity--results) "\n")
              "")
            "\n"
            (propertize "OS CHILD PROCESSES (not a subagent count)\n" 'face 'agent-rig-section)
            (or (alist-get 'children agent-rig-activity--results) "Loading…\n")
            (propertize "\nRECENT TERMINAL OUTPUT\n" 'face 'agent-rig-section)
            (or (alist-get 'output agent-rig-activity--results) "Unavailable"))
    (goto-char (min position (point-max)))
    (set-buffer-modified-p nil)))

(defun agent-rig-activity--probe (key command transform)
  (let ((target (current-buffer))
        (generation agent-rig-activity--generation)
        (output (generate-new-buffer " *rig activity probe*")))
    (condition-case err
        (let ((process (make-process
               :name "rig-activity" :buffer output :command command :noquery t
               :sentinel
               (lambda (process _event)
                 (when (memq (process-status process) '(exit signal))
                   (when (timerp (process-get process 'agent-rig-timeout))
                     (cancel-timer (process-get process 'agent-rig-timeout)))
                   (unwind-protect
                       (when (buffer-live-p target)
                         (with-current-buffer target
                           (setq agent-rig-activity--processes (delq process agent-rig-activity--processes))
                           (when (and (derived-mode-p 'agent-rig-activity-mode)
                                      (eq generation agent-rig-activity--generation))
                             (setf (alist-get key agent-rig-activity--results)
                                   (if (= (process-exit-status process) 0)
                                       (condition-case nil
                                           (funcall transform (with-current-buffer output (buffer-string)))
                                         (error "Unavailable (unsupported response)\n"))
                                     "Unavailable (probe failed)\n"))
                             (agent-rig-activity--render))))
                     (kill-buffer output)))))))
          (push process agent-rig-activity--processes)
          (process-put process 'agent-rig-timeout
                       (run-at-time 10 nil
                                    (lambda ()
                                      (when (process-live-p process) (delete-process process))))))
      (error (kill-buffer output)
             (setf (alist-get key agent-rig-activity--results) (error-message-string err))))))

(defun agent-rig-activity--codex (session)
  (when (and (equal (alist-get 'provider session) "codex")
             (alist-get 'conversation session))
    (let ((buffer (current-buffer)) (generation agent-rig-activity--generation) complete cancel)
      (setf (alist-get 'native agent-rig-activity--results) "Loading recorded conversation…")
      (setq cancel
            (agent-rig-codex-snapshot
             (alist-get 'conversation session) (alist-get 'directory session)
             (lambda (error result)
               (setq complete t)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (derived-mode-p 'agent-rig-activity-mode)
                              (eq generation agent-rig-activity--generation))
                     (setq agent-rig-activity--native-cancel nil)
                     (if error
                         (setf (alist-get 'native agent-rig-activity--results) (concat "Unavailable: " error))
                       (dolist (entry result)
                         (setf (alist-get (car entry) agent-rig-activity--results) (cdr entry)))
                     (agent-rig-activity--render))))))))
      (unless complete (setq agent-rig-activity--native-cancel cancel)))))

(defun agent-rig-activity-refresh ()
  (interactive)
  (agent-rig-activity--cancel)
  (setq agent-rig-activity--generation (list nil))
  (setq agent-rig-activity--started (float-time)
        agent-rig-activity--session (agent-rig--select)
        agent-rig-activity--results nil)
  (let* ((session agent-rig-activity--session)
         (pid (alist-get 'pid session))
         (native (agent-rig-activity--native-record session)))
    (when native
      (setf (alist-get 'native agent-rig-activity--results) (alist-get 'status native)))
    (setf (alist-get 'output agent-rig-activity--results)
          (condition-case err
              (agent-rig-tmux--run "capture-pane" "-p" "-t" (alist-get 'pane session) "-S" "-60")
            (error (error-message-string err))))
    (if (and pid (string-match-p "\\`[0-9]+\\'" pid)
             (equal (alist-get 'status session) "running"))
        (progn
          (agent-rig-activity--probe
           'children '("ps" "-axo" "pid=,ppid=,pcpu=,etime=,comm=")
           (lambda (text)
             (let ((rows (agent-rig-activity--descendants pid text)))
               (if rows
                   (concat "PID      CPU%  ELAPSED  COMMAND\n"
                           (mapconcat (lambda (row) (format "%-8s %s" (car row) (nth 2 row))) rows "\n") "\n")
                 "No descendant processes observed. Shared daemons are outside this tree.\n"))))
          (when (and (not native) (equal (alist-get 'provider session) "claude-code"))
            (setf (alist-get 'native agent-rig-activity--results) "Loading…")
            (agent-rig-activity--probe
             'native '("claude" "agents" "--json")
             (lambda (text) (agent-rig-activity--claude-status pid text)))))
      (setf (alist-get 'children agent-rig-activity--results) "No live PID available.\n"))
    (agent-rig-activity--codex session)
    (agent-rig-activity--render)))

(defun agent-rig-activity--cancel ()
  (setq agent-rig-activity--generation nil)
  (when agent-rig-activity--native-cancel (funcall agent-rig-activity--native-cancel))
  (setq agent-rig-activity--native-cancel nil)
  (dolist (process agent-rig-activity--processes)
    (when (process-live-p process) (delete-process process)))
  (setq agent-rig-activity--processes nil))

(defun agent-rig-activity--tick (buffer)
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'agent-rig-activity-mode)
                 (or (and (null agent-rig-activity--processes) (null agent-rig-activity--native-cancel))
                     (> (- (float-time) agent-rig-activity--started) 10)))
        (condition-case err (agent-rig-activity-refresh)
          (error
           (agent-rig-activity--stop)
           (setq header-line-format (concat "Activity stopped: " (error-message-string err)))
           (let ((inhibit-read-only t))
             (goto-char (point-min))
             (insert "STALE SNAPSHOT: " (error-message-string err) "\n\n"))))))))

(defun agent-rig-activity--stop ()
  (when (timerp agent-rig-activity--timer) (cancel-timer agent-rig-activity--timer))
  (setq agent-rig-activity--timer nil)
  (agent-rig-activity--cancel))

(defvar agent-rig-activity-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "M-<left>") #'agent-rig-overview)
    (define-key map (kbd "M-<right>") #'agent-rig-open)
    (define-key map (kbd "g") #'agent-rig-activity-refresh)
    (define-key map (kbd "i") #'agent-rig-set-conversation)
    map))

(define-derived-mode agent-rig-activity-mode special-mode "Rig Activity"
  (setq-local truncate-lines t)
  (setq-local header-line-format "M-← agents · M-→ terminal · i conversation ID · g refresh · q back")
  (add-hook 'kill-buffer-hook #'agent-rig-activity--stop nil t)
  (add-hook 'change-major-mode-hook #'agent-rig-activity--stop nil t)
  (setq agent-rig-activity--timer
        (run-at-time 3 3 #'agent-rig-activity--tick (current-buffer))))

(defun agent-rig-activity ()
  (interactive)
  (let ((session (agent-rig--select)))
    (with-current-buffer (get-buffer-create "*Agent Rig Activity*")
      (agent-rig-activity--cancel)
      (agent-rig-activity-mode)
      (setq-local agent-rig--terminal-session (alist-get 'session session))
      (setq-local agent-rig--project-directory (alist-get 'directory session))
      (agent-rig-activity-refresh)
      (agent-rig--display (current-buffer)))))

(provide 'agent-rig-activity)
