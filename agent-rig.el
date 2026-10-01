;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'project)
(require 'tabulated-list)
(require 'term)
(require 'agent-rig-providers)
(require 'agent-rig-tmux)

(defvar agent-rig-teams
  '(("pair" ("implementer" codex) ("reviewer" claude-code))
    ("mixed" ("implementer" codex) ("reviewer" claude-code) ("explorer" opencode))))
(defvar agent-rig-terminal-function #'agent-rig-terminal)
(defvar agent-rig-display-buffer-action nil)
(defvar agent-rig-refresh-interval 3)
(defvar agent-rig--source-window nil)
(defvar agent-rig--last-team "default")
(defvar-local agent-rig--project-directory nil)
(defvar-local agent-rig--show-all nil)
(defvar-local agent-rig--refresh-timer nil)
(defvar vterm-shell)
(defvar vterm-buffer-name-string)
(defvar vterm-kill-buffer-on-exit)
(defvar-local agent-rig--terminal-session nil)
(defvar-local agent-rig--prompt-targets nil)

(defun agent-rig--directory ()
  (or agent-rig--project-directory
      (let ((project (project-current nil)))
        (if project
            (if (fboundp 'project-root) (project-root project) (car (project-roots project)))
          default-directory))))

(defun agent-rig--name (name)
  (unless (and (stringp name) (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" name))
    (user-error "Names must contain only letters, digits, underscores and hyphens"))
  name)

(defun agent-rig--metadata (team seat provider directory)
  (agent-rig--name team)
  (agent-rig--name seat)
  (when (file-remote-p directory)
    (user-error "Agent Rig supports local project directories"))
  (unless (file-directory-p directory)
    (user-error "Project directory does not exist: %s" directory))
  `((version . 1) (team . ,team) (seat . ,seat)
    (provider . ,(symbol-name provider))
    (directory . ,(file-name-as-directory (file-truename directory)))))

(defun agent-rig--label (session)
  (format "%s/%s [%s] %s" (alist-get 'team session) (alist-get 'seat session)
          (alist-get 'provider session) (alist-get 'directory session)))

(defun agent-rig--select ()
  (let* ((sessions (agent-rig-tmux-sessions))
         (id (or agent-rig--terminal-session
                 (and (derived-mode-p 'agent-rig-mode) (tabulated-list-get-id))))
         (selected (cl-find id sessions :key (lambda (item) (alist-get 'session item)) :test #'equal)))
    (or selected
        (let ((choices (mapcar (lambda (item) (cons (agent-rig--label item) item)) sessions)))
          (unless choices (user-error "No managed agents; use agent-rig-start"))
          (cdr (assoc (completing-read "Agent: " choices nil t) choices))))))

(defun agent-rig-start (team seat provider directory)
  (interactive
   (let* ((provider (intern (completing-read "Provider: " agent-rig-providers nil t)))
          (team (read-string "Team: " nil nil agent-rig--last-team))
          (seat (read-string "Seat: " nil nil (symbol-name provider))))
     (list team seat provider (read-directory-name "Project: " (agent-rig--directory) nil t))))
  (let* ((metadata (agent-rig--metadata team seat provider directory))
         (command (agent-rig-provider-command provider))
         (session (agent-rig-tmux-start metadata command)))
    (setq agent-rig--last-team team)
    (when (called-interactively-p 'interactive)
      (agent-rig)
      (agent-rig-open (cl-find session (agent-rig-tmux-sessions)
                               :key (lambda (item) (alist-get 'session item)) :test #'equal)))
    session))

(defun agent-rig-start-team (team directory)
  (interactive
   (list (completing-read "Team template: " agent-rig-teams nil t)
         (read-directory-name "Project: " (agent-rig--directory) nil t)))
  (let ((spec (cdr (assoc team agent-rig-teams))) plans seats existing started)
    (unless spec (user-error "Unknown or empty team: %s" team))
    (dolist (member spec)
      (unless (and (listp member) (= (length member) 2) (symbolp (cadr member)))
        (user-error "Invalid team member: %S" member))
      (when (member (car member) seats) (user-error "Duplicate seat: %s" (car member)))
      (push (car member) seats)
      (push (list (agent-rig--metadata team (car member) (cadr member) directory)
                  (agent-rig-provider-command (cadr member))) plans))
    (setq existing (agent-rig-tmux-sessions))
    (dolist (plan plans)
      (when (cl-find-if
             (lambda (session)
               (cl-every (lambda (key) (equal (alist-get key session) (alist-get key (car plan))))
                         '(team seat directory))) existing)
        (user-error "Seat already exists: %s" (alist-get 'seat (car plan)))))
    (condition-case err
        (dolist (plan (nreverse plans))
          (push (agent-rig-tmux-start (car plan) (cadr plan)) started))
      (error
       (dolist (session started)
         (ignore-errors (agent-rig-tmux--run "kill-session" "-t" (concat "=" session))))
       (signal (car err) (cdr err))))
    (when (called-interactively-p 'interactive) (agent-rig))
    (nreverse started)))

(defun agent-rig--remember-source ()
  (unless (or agent-rig--terminal-session agent-rig--prompt-targets
              (derived-mode-p 'agent-rig-mode 'agent-rig-prompt-mode))
    (setq agent-rig--source-window (selected-window))))

(defun agent-rig--display (buffer)
  (let* ((side (if (< (frame-width) 160) 'bottom 'right))
         (existing (get-buffer-window buffer))
         (action (or agent-rig-display-buffer-action
                     `((display-buffer-reuse-window display-buffer-in-side-window)
                       (side . ,side) (slot . 0) (window-width . 0.45) (window-height . 0.45)))))
    (when (and (not agent-rig-display-buffer-action) existing
               (window-parameter existing 'window-side)
               (not (eq side (window-parameter existing 'window-side))))
      (delete-window existing))
    (pop-to-buffer buffer action)))

(defun agent-rig-return-to-code ()
  (interactive)
  (if (window-live-p agent-rig--source-window)
      (select-window agent-rig--source-window)
    (other-window 1)))

(defun agent-rig--terminal-name (session)
  (format "*Agent Rig %s/%s/%s [%s]*"
          (file-name-nondirectory (directory-file-name (alist-get 'directory session)))
          (alist-get 'team session) (alist-get 'seat session)
          (substring (secure-hash 'sha256 (concat agent-rig-tmux-socket (alist-get 'session session))) 0 6)))

(defvar agent-rig-terminal-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a") #'agent-rig)
    (define-key map (kbd "C-c C-s") #'agent-rig-send)
    (define-key map (kbd "C-c C-o") #'agent-rig-return-to-code)
    (define-key map (kbd "C-c C-n") #'agent-rig-next)
    (define-key map (kbd "C-c C-d") #'agent-rig-detach)
    map))

(defun agent-rig--prepare-terminal (buffer session)
  (with-current-buffer buffer
    (setq-local display-line-numbers nil)
    (setq-local agent-rig--terminal-session (alist-get 'session session))
    (setq-local agent-rig--project-directory (alist-get 'directory session))
    (setq-local header-line-format
                (format "%s | C-c a: agents  C-c C-s: prompt  C-c C-o: code  C-c C-n: next"
                        (agent-rig--label session)))
    (use-local-map (make-composed-keymap agent-rig-terminal-map (current-local-map))))
  (agent-rig--display buffer))

(defun agent-rig-terminal (session)
  (if (require 'vterm nil t)
      (agent-rig-vterm session)
    (agent-rig-term session)))

(defun agent-rig-vterm (session)
  (require 'vterm)
  (let* ((name (agent-rig--terminal-name session))
         (buffer (get-buffer name))
         (default-directory (alist-get 'directory session))
         (process-environment (copy-sequence process-environment))
         (vterm-buffer-name-string nil)
         (vterm-kill-buffer-on-exit nil)
         (vterm-shell (mapconcat #'shell-quote-argument
                                (list (or (executable-find agent-rig-tmux-program)
                                          (user-error "tmux is missing"))
                                      "-L" agent-rig-tmux-socket "attach-session" "-t"
                                      (concat "=" (alist-get 'session session))) " ")))
    (setenv "TMUX" nil)
    (unless (and buffer (process-live-p (get-buffer-process buffer)))
      (when buffer (kill-buffer buffer))
      (setq buffer (save-window-excursion (vterm name))))
    (agent-rig--prepare-terminal buffer session)))

(defun agent-rig-term (session)
  (let* ((name (agent-rig--terminal-name session))
         (buffer (get-buffer name))
         (default-directory (alist-get 'directory session))
         (process-environment (copy-sequence process-environment)))
    (setenv "TMUX" nil)
    (unless (and buffer (process-live-p (get-buffer-process buffer)))
      (when buffer (kill-buffer buffer))
      (setq buffer (make-term (substring name 1 -1) agent-rig-tmux-program nil
                              "-L" agent-rig-tmux-socket "attach-session" "-t"
                              (concat "=" (alist-get 'session session))))
      (with-current-buffer buffer (term-mode) (term-char-mode)))
    (agent-rig--prepare-terminal buffer session)))

(defun agent-rig-open (&optional session)
  (interactive)
  (agent-rig--remember-source)
  (funcall agent-rig-terminal-function (or session (agent-rig--select))))

(defun agent-rig-detach ()
  (interactive)
  (unless agent-rig--terminal-session (user-error "This is not an agent terminal"))
  (let ((process (get-buffer-process (current-buffer))))
    (when process (set-process-query-on-exit-flag process nil)))
  (kill-buffer (current-buffer))
  (agent-rig-return-to-code)
  (agent-rig))

(defun agent-rig-switch ()
  (interactive)
  (agent-rig--remember-source)
  (let* ((sessions (agent-rig-tmux-sessions))
         (directory (file-truename (agent-rig--directory)))
         (choices (mapcar (lambda (item) (cons (agent-rig--label item) item))
                          (append (cl-remove-if-not
                                   (lambda (item) (equal directory (alist-get 'directory item))) sessions)
                                  (cl-remove-if
                                   (lambda (item) (equal directory (alist-get 'directory item))) sessions)))))
    (unless choices (user-error "No agents yet; use agent-rig-start"))
    (agent-rig-open (cdr (assoc (completing-read "Switch agent: " choices nil t) choices)))))

(defun agent-rig-next ()
  (interactive)
  (let* ((current (agent-rig--select))
         (sessions (cl-remove-if-not
                    (lambda (item) (equal (alist-get 'directory item) (alist-get 'directory current)))
                    (agent-rig-tmux-sessions)))
         (index (cl-position (alist-get 'session current) sessions
                             :key (lambda (item) (alist-get 'session item)) :test #'equal)))
    (unless index (user-error "Agent disappeared; refresh the dashboard"))
    (agent-rig-open (nth (mod (1+ index) (length sessions)) sessions))))

(defun agent-rig-capture ()
  (interactive)
  (let* ((session (agent-rig--select))
         (text (agent-rig-tmux--run "capture-pane" "-p" "-J" "-S" "-2000"
                                   "-t" (alist-get 'pane session))))
    (with-current-buffer (get-buffer-create "*Agent Rig Output*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-rig--label session) "\n\n" text))
      (special-mode)
      (agent-rig--display (current-buffer)))))

(defun agent-rig-stop ()
  (interactive)
  (let ((session (agent-rig--select)))
    (when (yes-or-no-p (format "Stop %s and discard its terminal history? " (agent-rig--label session)))
      (agent-rig-tmux--run "kill-session" "-t" (concat "=" (alist-get 'session session)))
      (when (derived-mode-p 'agent-rig-mode) (agent-rig-refresh)))))

(defun agent-rig-restart ()
  (interactive)
  (let ((session (agent-rig--select)))
    (unless (equal (alist-get 'status session) "exited")
      (user-error "Only exited agents can be restarted"))
    (when (yes-or-no-p "Start a fresh provider conversation in this seat? ")
      (agent-rig-tmux--run "respawn-pane" "-t" (alist-get 'pane session))
      (agent-rig-open session))))

(defvar agent-rig-prompt-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map text-mode-map)
    (define-key map (kbd "C-c C-c") #'agent-rig-paste-prompt)
    (define-key map (kbd "C-c C-o") #'agent-rig-return-to-code)
    map))

(define-derived-mode agent-rig-prompt-mode text-mode "Agent Prompt"
  (visual-line-mode 1))

(defun agent-rig--compose (targets &optional text)
  (agent-rig--remember-source)
  (let ((buffer (generate-new-buffer "*Agent Rig Prompt*")))
    (with-current-buffer buffer
      (agent-rig-prompt-mode)
      (setq-local agent-rig--project-directory (alist-get 'directory (car targets)))
      (setq default-directory agent-rig--project-directory)
      (setq-local agent-rig--prompt-targets (mapcar (lambda (item) (alist-get 'session item)) targets))
      (setq-local header-line-format
                  (format "To: %s | C-c C-c: paste draft, then submit in agent terminal"
                          (mapconcat #'agent-rig--label targets ", ")))
      (when text (insert text)))
    (agent-rig--display buffer)))

(defun agent-rig-send ()
  (interactive)
  (agent-rig--compose (list (agent-rig--select))))

(defun agent-rig-send-region (begin end)
  (interactive "r")
  (let ((text (agent-rig--context begin end)))
    (agent-rig--compose (list (agent-rig--select)) text)))

(defun agent-rig--context (begin end)
  (format "File: %s\nLines: %d-%d\nBuffer has unsaved changes: %s\n\n%s"
          (if buffer-file-name (file-relative-name buffer-file-name (agent-rig--directory)) (buffer-name))
          (line-number-at-pos begin) (line-number-at-pos (max begin (1- end)))
          (if (buffer-modified-p) "yes" "no") (buffer-substring-no-properties begin end)))

(defun agent-rig-send-buffer ()
  (interactive)
  (agent-rig-send-region (point-min) (point-max)))

(defun agent-rig-send-diff ()
  (interactive)
  (let* ((directory (agent-rig--directory))
         (text (with-temp-buffer
                 (let ((default-directory directory))
                   (unless (zerop (process-file "git" nil t nil "diff" "--no-ext-diff" "HEAD" "--"))
                     (user-error "Cannot read Git diff: %s" (buffer-string))))
                 (when (zerop (buffer-size)) (user-error "No tracked changes against HEAD"))
                 (concat "Tracked working-tree diff against HEAD (untracked files excluded):\n\n"
                         (buffer-string)))))
    (agent-rig--compose (list (agent-rig--select)) text)))

(defun agent-rig-broadcast ()
  (interactive)
  (let* ((selected (agent-rig--select))
         (targets (cl-remove-if-not
                   (lambda (item)
                     (and (equal (alist-get 'team item) (alist-get 'team selected))
                          (equal (alist-get 'directory item) (alist-get 'directory selected))
                          (equal (alist-get 'status item) "running")))
                   (agent-rig-tmux-sessions))))
    (unless targets (user-error "No running agents in this team"))
    (agent-rig--compose targets)))

(defun agent-rig-paste-prompt ()
  (interactive)
  (unless agent-rig--prompt-targets (user-error "No pending prompt targets"))
  (let ((text (buffer-substring-no-properties (point-min) (point-max)))
        (sessions (agent-rig-tmux-sessions)) delivered)
    (dolist (target (copy-sequence agent-rig--prompt-targets))
      (let ((session (cl-find target sessions :key (lambda (item) (alist-get 'session item)) :test #'equal)))
        (unless session (user-error "Agent disappeared: %s" target))
        (agent-rig-tmux-paste session text)
        (setq agent-rig--prompt-targets (delete target agent-rig--prompt-targets))
        (setq header-line-format (format "Remaining targets: %d | C-c C-c: retry delivery"
                                         (length agent-rig--prompt-targets)))
        (push session delivered)))
    (setq header-line-format "Draft pasted. Submit it in each agent terminal.")
    (set-buffer-modified-p nil)
    (message "Pasted to %d agent(s); submit in their terminals" (length delivered))
    (when (= (length delivered) 1) (agent-rig-open (car delivered)))))

(defun agent-rig-refresh ()
  (interactive)
  (let* ((sessions (agent-rig-tmux-sessions))
         (visible (if agent-rig--show-all sessions
                    (cl-remove-if-not
                     (lambda (item) (equal (alist-get 'directory item) agent-rig--project-directory))
                     sessions))))
    (setq-local display-line-numbers nil)
    (setq tabulated-list-format
          (vconcat '(("Team" 14 t) ("Seat" 18 t) ("Provider" 12 t) ("Process" 10 t))
                   (when agent-rig--show-all '(("Project" 0 t)))))
    (tabulated-list-init-header)
    (setq tabulated-list-entries
          (mapcar (lambda (session)
                    (list (alist-get 'session session)
                          (vconcat (list (alist-get 'team session) (alist-get 'seat session)
                                  (alist-get 'provider session)
                                  (if (equal (alist-get 'status session) "exited")
                                      (propertize (concat "exited:" (alist-get 'exit-code session)) 'face 'warning)
                                    (propertize "running" 'face 'success)))
                                   (when agent-rig--show-all
                                     (list (abbreviate-file-name (alist-get 'directory session))))))) visible))
    (setq mode-line-process (format " [%d agents | %s]" (length visible)
                                    (if agent-rig--show-all "all projects" "this project")))
    (tabulated-list-print t)
    (unless visible
      (let ((inhibit-read-only t))
        (insert "\n  No agents in this view.\n\n  n  Launch an agent     t  Launch a team\n  a  Toggle all projects  ?  Commands and setup\n")))
    (force-mode-line-update)))

(defun agent-rig-toggle-projects ()
  (interactive)
  (setq agent-rig--show-all (not agent-rig--show-all))
  (agent-rig-refresh))

(defun agent-rig--cancel-refresh ()
  (when (timerp agent-rig--refresh-timer) (cancel-timer agent-rig--refresh-timer))
  (setq agent-rig--refresh-timer nil))

(defun agent-rig--refresh-visible (buffer)
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (condition-case err (agent-rig-refresh)
        (error (setq mode-line-process (format " [%s]" (error-message-string err))))))))

(defvar agent-rig--commands
  '(("n" agent-rig-start "New agent")
    ("t" agent-rig-start-team "Launch team")
    ("RET" agent-rig-open "Open terminal")
    ("TAB" agent-rig-switch "Switch agent")
    ("s" agent-rig-send "Compose prompt")
    ("b" agent-rig-broadcast "Broadcast to team")
    ("o" agent-rig-capture "Capture output")
    ("r" agent-rig-restart "Restart exited agent")
    ("k" agent-rig-stop "Stop agent")
    ("a" agent-rig-toggle-projects "Toggle this project / all projects")
    ("g" agent-rig-refresh "Refresh")
    ("?" agent-rig-help "Commands and setup")
    ("C-c C-o" agent-rig-return-to-code "Return to source window")))

(defun agent-rig-help ()
  (interactive)
  (with-current-buffer (get-buffer-create "*Agent Rig Help*")
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "Agent Rig\n\n")
      (dolist (command agent-rig--commands)
        (insert (format "%-12s %s\n" (car command) (nth 2 command))))
      (insert "\nRuntime\n\n")
      (insert (format "tmux: %s\nTerminal: %s\n" (or (executable-find agent-rig-tmux-program) "MISSING: install tmux")
                      (if (locate-library "vterm") "vterm" "built-in term")))
      (dolist (provider agent-rig-providers)
        (insert (format "%s: %s\n" (car provider)
                        (condition-case err (car (agent-rig-provider-command (car provider)))
                          (error (error-message-string err))))))
      (insert "\nPrompts: compose in Emacs; C-c C-c pastes the draft. Submit in the agent terminal.\nClosing a terminal detaches it. Use k to stop the agent.\n"))
    (special-mode)
    (goto-char (point-min))
    (agent-rig--display (current-buffer))))

(defvar agent-rig-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (dolist (command agent-rig--commands)
      (define-key map (kbd (car command)) (cadr command)))
    map))

(define-derived-mode agent-rig-mode tabulated-list-mode "Agent Rig"
  (setq tabulated-list-format [("Team" 14 t) ("Seat" 18 t) ("Provider" 12 t)
                               ("Process" 10 t) ("Project" 0 t)])
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key '("Team" . nil))
  (setq-local truncate-lines t)
  (setq-local mode-line-buffer-identification '("Agent Rig: n new | t team | RET terminal | ? help"))
  (add-hook 'tabulated-list-revert-hook #'agent-rig-refresh nil t)
  (add-hook 'kill-buffer-hook #'agent-rig--cancel-refresh nil t)
  (add-hook 'change-major-mode-hook #'agent-rig--cancel-refresh nil t)
  (when (and (numberp agent-rig-refresh-interval) (> agent-rig-refresh-interval 0))
    (setq agent-rig--refresh-timer
          (run-with-idle-timer agent-rig-refresh-interval t #'agent-rig--refresh-visible (current-buffer))))
  (tabulated-list-init-header))

(defun agent-rig (&optional all-projects)
  (interactive "P")
  (agent-rig--remember-source)
  (let ((directory (file-name-as-directory (file-truename (agent-rig--directory)))))
    (with-current-buffer (get-buffer-create "*Agent Rig*")
      (unless (derived-mode-p 'agent-rig-mode) (agent-rig-mode))
      (setq agent-rig--project-directory directory default-directory directory
            agent-rig--show-all (not (null all-projects)))
      (agent-rig-refresh)
      (agent-rig--display (current-buffer)))))

(provide 'agent-rig)
