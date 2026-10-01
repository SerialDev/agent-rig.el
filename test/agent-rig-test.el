;; -*- lexical-binding: t; -*-
(require 'ert)
(require 'agent-rig)

(defmacro agent-rig-test-with-server (&rest body)
  `(let ((agent-rig-tmux-socket (format "agent-rig-test-%s-%s" (emacs-pid) (random 1000000))))
     (unwind-protect (condition-case failure (progn ,@body)
                       (error
                        (message "tmux inventory: %S"
                                 (agent-rig-tmux--call "list-panes" "-a" "-F"
                                                      "#{session_name}|#{pane_id}|#{pane_dead}|#{@agent-rig}|#{bracket_paste_flag}|#{pane_start_command}"))
                        (dolist (session (agent-rig-tmux-sessions))
                          (message "tmux history: %S"
                                   (agent-rig-tmux--call "capture-pane" "-p" "-S" "-"
                                                        "-t" (alist-get 'pane session))))
                        (signal (car failure) (cdr failure))))
       (ignore-errors (agent-rig-tmux--run "kill-server")))))

(defun agent-rig-test-wait (predicate)
  (let ((deadline (+ (float-time) 5)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (should (funcall predicate))))

(ert-deftest agent-rig-provider-validates-before-launch ()
  (let ((agent-rig-providers '((missing :command ("agent-rig-no-such-executable")))))
    (should-error (agent-rig-provider-command 'missing) :type 'user-error)
    (should-error (agent-rig-provider-command 'unknown) :type 'user-error)))

(ert-deftest agent-rig-rejects-invalid-identities-and-remote-paths ()
  (dolist (name '("" "-bad" "a:b" "a.b" "a\nb" "a;b"))
    (should-error (agent-rig--name name) :type 'user-error))
  (should (equal (agent-rig--name "reviewer_2-main") "reviewer_2-main"))
  (should-error (agent-rig--metadata "team" "seat" 'codex "/ssh:example:/tmp/")
                :type 'user-error))

(ert-deftest agent-rig-team-preflight-does-not-launch-partial-team ()
  (let ((agent-rig-teams '(("pair" ("one" valid) ("two" missing))))
        (agent-rig-providers '((valid :command ("sh"))
                               (missing :command ("agent-rig-no-such-executable"))))
        launched)
    (cl-letf (((symbol-function 'agent-rig-tmux-start)
               (lambda (&rest _) (setq launched t))))
      (should-error (agent-rig-start-team "pair" temporary-file-directory) :type 'user-error)
      (should-not launched))))

(ert-deftest agent-rig-team-rejects-duplicate-seats ()
  (let ((agent-rig-teams '(("pair" ("one" valid) ("one" valid))))
        (agent-rig-providers '((valid :command ("sh")))))
    (should-error (agent-rig-start-team "pair" temporary-file-directory) :type 'user-error)))

(ert-deftest agent-rig-discovery-rejects-corrupt-metadata ()
  (cl-letf (((symbol-function 'agent-rig-tmux--call)
             (lambda (&rest _) '(0 . "ar-test|%1|0||invalid!"))))
    (should-not (agent-rig-tmux-sessions))))

(ert-deftest agent-rig-discovery-does-not-hide-server-errors ()
  (cl-letf (((symbol-function 'agent-rig-tmux--call)
             (lambda (&rest _) '(1 . "permission denied"))))
    (should-error (agent-rig-tmux-sessions))))

(ert-deftest agent-rig-paste-refuses-control-characters-and-unready-terminals ()
  (let ((session '((status . "running") (pane . "%1"))) calls)
    (cl-letf (((symbol-function 'agent-rig-tmux--run)
               (lambda (&rest args) (push args calls) "0")))
      (should-error (agent-rig-tmux-paste session "bad\033text") :type 'user-error)
      (should-not calls)
      (should-error (agent-rig-tmux-paste session "hello") :type 'user-error)
      (should (equal (mapcar #'car calls) '("display-message"))))))

(ert-deftest agent-rig-prompt-retry-does-not-duplicate-successful-deliveries ()
  (let ((sessions '(((session . "one")) ((session . "two")))) delivered)
    (with-temp-buffer
      (insert "hello")
      (setq-local agent-rig--prompt-targets '("one" "two"))
      (cl-letf (((symbol-function 'agent-rig-tmux-sessions) (lambda () sessions))
                ((symbol-function 'agent-rig-tmux-paste)
                 (lambda (item _text)
                   (if (equal (alist-get 'session item) "two")
                       (error "not ready")
                     (push (alist-get 'session item) delivered)))))
        (should-error (agent-rig-paste-prompt))
        (should (equal delivered '("one")))
        (should (equal agent-rig--prompt-targets '("two")))))))

(ert-deftest agent-rig-paste-supports-both-tmux-sanitization-contracts ()
  (dolist (usage '("paste-buffer (pasteb) [-dpr]" "paste-buffer (pasteb) [-dprS]"))
    (let (paste)
      (cl-letf (((symbol-function 'agent-rig-tmux--run)
                 (lambda (&rest args)
                   (cond
                    ((equal (car args) "display-message") "1")
                    ((equal (car args) "list-commands") usage)
                    ((equal (car args) "paste-buffer") (setq paste args))
                    (t "")))))
        (agent-rig-tmux-paste '((status . "running") (pane . "%1")) "line one\nline two")
        (should (equal (not (null (member "-S" paste)))
                       (not (null (string-match-p "dprS" usage)))))))))

(ert-deftest agent-rig-metadata-roundtrip ()
  (let* ((metadata (agent-rig--metadata "team" "seat" 'codex temporary-file-directory))
         (encoded (agent-rig-tmux--encode metadata)))
    (should (equal metadata (agent-rig-tmux--decode encoded)))
    (cl-letf (((symbol-function 'agent-rig-tmux--call)
               (lambda (&rest _) (cons 0 (concat "ar-test|%1|0||" encoded)))))
      (should (= 1 (length (agent-rig-tmux-sessions)))))))

(ert-deftest agent-rig-team-rolls-back-only-new-sessions ()
  (let ((agent-rig-teams '(("pair" ("one" valid) ("two" valid))))
        (agent-rig-providers '((valid :command ("sh"))))
        (attempt 0) stopped)
    (cl-letf (((symbol-function 'agent-rig-tmux-sessions) (lambda () nil))
              ((symbol-function 'agent-rig-tmux-start)
               (lambda (&rest _)
                 (setq attempt (1+ attempt))
                 (if (= attempt 1) "new-session" (error "launch failed"))))
              ((symbol-function 'agent-rig-tmux--run)
               (lambda (&rest args) (push args stopped))))
      (should-error (agent-rig-start-team "pair" temporary-file-directory))
      (should (equal stopped '(("kill-session" "-t" "=new-session")))))))

(ert-deftest agent-rig-server-persists-and-isolates-projects ()
  (agent-rig-test-with-server
   (let* ((directory (make-temp-file "agent-rig-project-" t))
          (agent-rig-providers '((fixture :command ("sh" "-c" "exec sleep 60"))))
          first second)
     (unwind-protect
         (progn
           (should-not (agent-rig-tmux-sessions))
           (setq first (agent-rig-start "team" "seat" 'fixture temporary-file-directory))
           (setq second (agent-rig-start "team" "seat" 'fixture directory))
           (should-not (equal first second))
           (should (= 2 (length (agent-rig-tmux-sessions))))
           (should-error (agent-rig-start "team" "seat" 'fixture directory))
           (should (= 2 (length (agent-rig-tmux-sessions))))
           (with-temp-buffer
             (should (zerop (call-process invocation-name nil t nil "-Q" "--batch"
                                         "-L" default-directory "-l" "agent-rig"
                                         "--eval" (prin1-to-string
                                                   `(progn
                                                      (setq agent-rig-tmux-socket ,agent-rig-tmux-socket)
                                                      (princ (length (agent-rig-tmux-sessions))))))))
             (should (equal (buffer-string) "2"))))
       (delete-directory directory)))))

(ert-deftest agent-rig-exited-agent-retains-status-and-output ()
  (agent-rig-test-with-server
   (let* ((agent-rig-providers '((fixture :command ("sh" "-c" "printf failure; exit 7"))))
          (id (agent-rig-start "team" "seat" 'fixture temporary-file-directory)))
     (agent-rig-test-wait
      (lambda () (equal (alist-get 'status (car (agent-rig-tmux-sessions))) "exited")))
     (let ((session (car (agent-rig-tmux-sessions))))
       (should (equal (alist-get 'session session) id))
       (should (equal (alist-get 'exit-code session) "7"))
       (should (string-match-p "failure" (agent-rig-tmux--run "capture-pane" "-p" "-S" "-" "-t"
                                                                          (alist-get 'pane session))))))))

(ert-deftest agent-rig-preserves-arguments-and-multiline-paste ()
  (agent-rig-test-with-server
   (let* ((directory (make-temp-file "agent rig ' project-" t))
          (output (expand-file-name "output" directory))
          (literal "$(touch SHOULD_NOT_EXIST); ' quoted λ")
          (agent-rig-providers
           `((fixture :command
              ("sh" "-c" "stty -echo -icanon; printf '\033[?2004h'; printf '%s\\n' \"$2\" > \"$1\"; exec cat >> \"$1\""
               "fixture" ,output ,literal))))
          (text "first\nsecond $(touch ALSO_NOT_CREATED)\nλ")
          session)
     (unwind-protect
         (progn
           (agent-rig-start "team" "seat" 'fixture directory)
           (setq session (car (agent-rig-tmux-sessions)))
           (if (string-empty-p (agent-rig-tmux--run "display-message" "-p" "-t"
                                                  (alist-get 'pane session) "#{bracket_paste_flag}"))
               (should-error (agent-rig-tmux-paste session text) :type 'user-error)
             (progn
           (agent-rig-test-wait
            (lambda () (equal "1" (agent-rig-tmux--run "display-message" "-p" "-t"
                                                     (alist-get 'pane session) "#{bracket_paste_flag}"))))
           (agent-rig-tmux-paste session text)
           (agent-rig-test-wait
            (lambda ()
              (and (file-exists-p output)
                   (with-temp-buffer
                     (insert-file-contents output)
                     (equal (buffer-string) (concat literal "\n\033[200~" text "\033[201~"))))))
           (should-not (file-exists-p (expand-file-name "SHOULD_NOT_EXIST" directory)))
           (should-not (file-exists-p (expand-file-name "ALSO_NOT_CREATED" directory))))))
       (when (file-exists-p output)
         (message "fixture received: %S" (with-temp-buffer (insert-file-contents output) (buffer-string))))
       (delete-directory directory t)))))

(ert-deftest agent-rig-dashboard-keeps-project-context-and-filters ()
  (let ((agent-rig-refresh-interval nil)
        (directory (file-name-as-directory (file-truename temporary-file-directory))))
    (with-temp-buffer
      (agent-rig-mode)
      (setq-local agent-rig--project-directory directory)
      (let ((sessions `(((session . "one") (team . "team") (seat . "one")
                         (provider . "codex") (status . "running") (directory . ,directory))
                        ((session . "two") (team . "team") (seat . "two")
                         (provider . "claude-code") (status . "running") (directory . "/other/")))))
        (cl-letf (((symbol-function 'agent-rig-tmux-sessions) (lambda () sessions)))
          (agent-rig-refresh)
          (should (equal (mapcar #'car tabulated-list-entries) '("one")))
          (should (equal (agent-rig--directory) directory))
          (agent-rig-toggle-projects)
          (should (= (length tabulated-list-entries) 2)))))))

(ert-deftest agent-rig-empty-dashboard-explains-next-action ()
  (let ((agent-rig-refresh-interval nil))
    (with-temp-buffer
      (agent-rig-mode)
      (cl-letf (((symbol-function 'agent-rig-tmux-sessions) (lambda () nil)))
        (agent-rig-refresh)
        (should (string-match-p "Launch an agent" (buffer-string)))
        (agent-rig-refresh)
        (goto-char (point-min))
        (should (= 1 (how-many "Launch an agent" (point-min) (point-max))))))))

(ert-deftest agent-rig-context-identifies-file-lines-and-unsaved-state ()
  (with-temp-buffer
    (insert "first\nsecond\nthird\n")
    (setq buffer-file-name "/tmp/project/example.el")
    (setq-local agent-rig--project-directory "/tmp/project/")
    (should (equal (agent-rig--context 7 14)
                   "File: example.el\nLines: 2-2\nBuffer has unsaved changes: yes\n\nsecond\n"))))

(ert-deftest agent-rig-terminal-map-preserves-user-navigation ()
  (let ((agent-rig--source-window (selected-window))
        (session '((session . "ar-test") (directory . "/tmp/")
                   (team . "team") (seat . "seat") (provider . "codex"))))
    (with-temp-buffer
      (let ((map (make-sparse-keymap)))
        (define-key map (kbd "M-w") #'other-window)
        (use-local-map map))
      (cl-letf (((symbol-function 'agent-rig--display) #'ignore))
        (agent-rig--prepare-terminal (current-buffer) session))
      (should (eq (key-binding (kbd "M-w")) #'other-window))
      (should (eq (key-binding (kbd "C-c a")) #'agent-rig))
      (should (eq (key-binding (kbd "C-c C-o")) #'agent-rig-return-to-code))
      (should (equal agent-rig--terminal-session "ar-test")))))

(ert-deftest agent-rig-dashboard-cancels-its-timer-on-kill ()
  (let ((buffer (generate-new-buffer " *agent-rig-timer*"))
        (agent-rig-refresh-interval 3) timer)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (agent-rig-mode)
            (setq timer agent-rig--refresh-timer))
          (should (timerp timer))
          (kill-buffer buffer)
          (should-not (memq timer timer-idle-list)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest agent-rig-prompt-composition-preserves-source-and-project ()
  (let ((source (selected-window)) (agent-rig--source-window nil) composed
        (session '((session . "ar-test") (directory . "/tmp/")
                   (team . "team") (seat . "seat") (provider . "codex"))))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-rig--display) (lambda (buffer) (setq composed buffer))))
          (agent-rig--compose (list session) "hello")
          (should (eq agent-rig--source-window source))
          (with-current-buffer composed
            (should (derived-mode-p 'agent-rig-prompt-mode))
            (should (equal default-directory "/tmp/"))
            (should (equal agent-rig--prompt-targets '("ar-test")))
            (should (equal (buffer-string) "hello"))
            (should (eq (key-binding (kbd "C-c C-c")) #'agent-rig-paste-prompt))))
      (when (buffer-live-p composed) (kill-buffer composed)))))

(ert-deftest agent-rig-panel-keeps-source-visible-and-returnable ()
  (let ((source (generate-new-buffer " *agent-rig-source*"))
        (panel (generate-new-buffer " *agent-rig-panel*"))
        (agent-rig-display-buffer-action nil)
        (agent-rig--source-window nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer source)
          (agent-rig--remember-source)
          (agent-rig--display panel)
          (should (eq (window-buffer) panel))
          (should (get-buffer-window source))
          (agent-rig-return-to-code)
          (should (eq (window-buffer) source)))
      (kill-buffer source)
      (kill-buffer panel))))

(ert-deftest agent-rig-refresh-retains-selected-agent-after-list-changes ()
  (let ((agent-rig-refresh-interval nil)
        (sessions '(((session . "one") (team . "z") (seat . "one")
                     (provider . "codex") (status . "running") (directory . "/tmp/")))))
    (with-temp-buffer
      (agent-rig-mode)
      (setq-local agent-rig--project-directory "/tmp/")
      (cl-letf (((symbol-function 'agent-rig-tmux-sessions) (lambda () sessions)))
        (agent-rig-refresh)
        (goto-char (point-min))
        (should (equal (tabulated-list-get-id) "one"))
        (push '((session . "two") (team . "a") (seat . "two") (provider . "codex")
                (status . "running") (directory . "/tmp/")) sessions)
        (agent-rig-refresh)
        (should (equal (tabulated-list-get-id) "one"))
        (should-not display-line-numbers)))))

(ert-deftest agent-rig-resume-requires-explicit-safe-id ()
  (let ((agent-rig-providers '((codex :command ("sh") :resume ("resume")))))
    (should (equal (cdr (agent-rig-provider-resume-command 'codex "session-123"))
                   '("resume" "session-123")))
    (dolist (id '("" "--last" "a\nb" "a b"))
      (should-error (agent-rig-provider-resume-command 'codex id) :type 'user-error))))

(ert-deftest agent-rig-snapshot-validates-every-seat-before-starting ()
  (let* ((agent-rig-state-directory (make-temp-file "agent-rig-state-" t))
         (file (expand-file-name "project.json" agent-rig-state-directory))
         (directory (file-name-as-directory (file-truename temporary-file-directory)))
         (seat (agent-rig--metadata "team" "one" 'codex directory))
         launched)
    (unwind-protect
        (progn
          (agent-rig-state--write file `((version . 1) (project . ,directory)
                                         (seats . ,(vector seat seat))))
          (cl-letf (((symbol-function 'agent-rig-tmux-start)
                     (lambda (&rest _) (setq launched t))))
            (should-error (agent-rig-restore file) :type 'user-error)
            (should-not launched)))
      (delete-directory agent-rig-state-directory t))))

(ert-deftest agent-rig-snapshot-survives-server-loss-and-restore-is-idempotent ()
  (agent-rig-test-with-server
   (let* ((agent-rig-state-directory (make-temp-file "agent-rig-state-" t))
          (agent-rig-providers '((fixture :command ("sh" "-c" "sleep 30"))))
          (agent-rig--project-directory temporary-file-directory)
          file)
     (unwind-protect
         (progn
           (agent-rig-start "team" "one" 'fixture temporary-file-directory)
           (setq file (agent-rig-save))
           (should (= (logand (file-modes file) #o777) #o600))
           (agent-rig-tmux--run "kill-server")
           (agent-rig-test-wait (lambda () (null (agent-rig-tmux-sessions))))
           (cl-letf (((symbol-function 'agent-rig--display) #'ignore))
             (should (equal (alist-get 'result (car (agent-rig-restore file)))
                            "fresh conversation launched"))
             (should (equal (alist-get 'result (car (agent-rig-restore file)))
                            "already present; unchanged")))
           (should (= (length (agent-rig-tmux-sessions)) 1))
           (should (file-exists-p (expand-file-name "last-restore.json" agent-rig-state-directory))))
       (delete-directory agent-rig-state-directory t)))))

(ert-deftest agent-rig-adoption-preserves-process-and-rejects-seat-collision ()
  (agent-rig-test-with-server
   (let* ((pane (agent-rig-tmux--run "new-session" "-d" "-P" "-F" "#{pane_id}"
                                    "-s" "outside" "-c" temporary-file-directory "sleep 30"))
          (pid (agent-rig-tmux--run "display-message" "-p" "-t" pane "#{pane_pid}"))
          (agent-rig-providers '((fixture :command ("sh")))))
     (should (= (length (agent-rig-tmux-unmanaged)) 1))
     (cl-letf (((symbol-function 'completing-read)
                (lambda (prompt choices &rest _)
                  (if (string-prefix-p "Provider" prompt) "fixture" (caar choices))))
               ((symbol-function 'read-string)
                (lambda (prompt &rest _) (if (equal prompt "Team: ") "adopted" "worker")))
               ((symbol-function 'agent-rig) #'ignore))
       (agent-rig-adopt))
     (should (equal pid (agent-rig-tmux--run "display-message" "-p" "-t" pane "#{pane_pid}")))
     (should-not (agent-rig-tmux-unmanaged))
     (should (equal (alist-get 'session (car (agent-rig-tmux-sessions))) "outside"))
     (should-error (agent-rig-start "adopted" "worker" 'fixture temporary-file-directory)
                   :type 'user-error))))

(ert-deftest agent-rig-focus-restores-source-layout ()
  (save-window-excursion
    (let ((agent-rig--window-configuration nil)
          (buffer (generate-new-buffer " *agent-focus-test*")))
      (unwind-protect
          (progn
            (delete-other-windows)
            (split-window-right)
            (with-current-buffer buffer (agent-rig-prompt-mode))
            (agent-rig--display buffer)
            (let ((count (length (window-list))))
              (agent-rig-toggle-focus)
              (should (= (length (window-list)) 1))
              (should (eq (window-buffer) buffer))
              (agent-rig-toggle-focus)
              (should (= (length (window-list)) count))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest agent-rig-worktree-isolation-preserves-original-checkout ()
  (let* ((root (make-temp-file "agent-rig-git-" t))
         (project (expand-file-name "project/" root))
         (worktree (expand-file-name "isolated" root))
         (agent-rig-providers '((fixture :command ("sh")))))
    (unwind-protect
        (progn
          (make-directory project)
          (let ((default-directory project))
            (should (zerop (process-file "git" nil nil nil "init" "-b" "main")))
            (should (zerop (process-file "git" nil nil nil "-c" "user.name=Test" "-c"
                                         "user.email=test@example.invalid" "commit" "--allow-empty" "-m" "initial")))
            (cl-letf (((symbol-function 'agent-rig-start)
                       (lambda (_team _seat _provider directory)
                         (should (equal directory worktree)) "fixture")))
              (agent-rig-worktree-start "team" "seat" 'fixture project worktree "codex/seat"))
            (with-temp-buffer
              (process-file "git" nil t nil "branch" "--show-current")
              (should (equal (string-trim (buffer-string)) "main"))))
          (should (file-exists-p (expand-file-name ".git" worktree))))
      (delete-directory root t))))
