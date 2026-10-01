;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar-local agent-rig-activity--generation 0)
(defvar-local agent-rig-activity--timer nil)
(defvar-local agent-rig-activity--started 0)
(defvar-local agent-rig-activity--processes nil)
(defvar-local agent-rig-activity--session nil)
(defvar-local agent-rig-activity--results nil)

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
            (format "Native activity: %s\nSubagents: unavailable from this provider's process inventory\n\n"
                    (or (alist-get 'native agent-rig-activity--results) "unavailable"))
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
        (push (make-process
               :name "rig-activity" :buffer output :command command :noquery t
               :sentinel
               (lambda (process _event)
                 (when (memq (process-status process) '(exit signal))
                   (unwind-protect
                       (when (buffer-live-p target)
                         (with-current-buffer target
                           (setq agent-rig-activity--processes (delq process agent-rig-activity--processes))
                           (when (= generation agent-rig-activity--generation)
                             (setf (alist-get key agent-rig-activity--results)
                                   (if (= (process-exit-status process) 0)
                                       (condition-case nil
                                           (funcall transform (with-current-buffer output (buffer-string)))
                                         (error "Unavailable (unsupported response)\n"))
                                     "Unavailable (probe failed)\n"))
                             (agent-rig-activity--render))))
                     (kill-buffer output)))))
              agent-rig-activity--processes)
      (error (kill-buffer output)
             (setf (alist-get key agent-rig-activity--results) (error-message-string err))))))

(defun agent-rig-activity-refresh ()
  (interactive)
  (agent-rig-activity--cancel)
  (cl-incf agent-rig-activity--generation)
  (setq agent-rig-activity--started (float-time)
        agent-rig-activity--session (agent-rig--select)
        agent-rig-activity--results nil)
  (let* ((session agent-rig-activity--session)
         (pid (alist-get 'pid session)))
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
          (when (equal (alist-get 'provider session) "claude-code")
            (setf (alist-get 'native agent-rig-activity--results) "Loading…")
            (agent-rig-activity--probe
             'native '("claude" "agents" "--json")
             (lambda (text) (agent-rig-activity--claude-status pid text)))))
      (setf (alist-get 'children agent-rig-activity--results) "No live PID available.\n"))
    (agent-rig-activity--render)))

(defun agent-rig-activity--cancel ()
  (dolist (process agent-rig-activity--processes)
    (when (process-live-p process) (delete-process process)))
  (setq agent-rig-activity--processes nil))

(defun agent-rig-activity--tick (buffer)
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (or (null agent-rig-activity--processes)
                (> (- (float-time) agent-rig-activity--started) 10))
        (condition-case err (agent-rig-activity-refresh)
          (error (setq header-line-format (error-message-string err))))))))

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
    map))

(define-derived-mode agent-rig-activity-mode special-mode "Rig Activity"
  (setq-local truncate-lines t)
  (setq-local header-line-format "M-← all agents · M-→ terminal · g refresh · q back")
  (add-hook 'kill-buffer-hook #'agent-rig-activity--stop nil t)
  (add-hook 'change-major-mode-hook #'agent-rig-activity--stop nil t)
  (setq agent-rig-activity--timer
        (run-with-idle-timer 3 t #'agent-rig-activity--tick (current-buffer))))

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
