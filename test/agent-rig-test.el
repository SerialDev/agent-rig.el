;; -*- lexical-binding: t; -*-
(require 'ert)
(require 'agent-rig)

(defmacro agent-rig-test-with-server (&rest body)
  `(let ((agent-rig-tmux-socket (format "agent-rig-test-%s-%s" (emacs-pid) (random 1000000))))
     (unwind-protect (condition-case failure (progn ,@body)
                       (error
                        (message "tmux inventory: %S"
                                 (agent-rig-tmux--call "list-panes" "-a" "-F"
                                                      "#{session_name}|#{pane_id}|#{pane_dead}|#{@agent-rig}"))
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
             (lambda (&rest _) '(0 . "ar-test\t%1\t0\t\tinvalid!"))))
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
               (lambda (&rest _) (cons 0 (concat "ar-test\t%1\t0\t\t" encoded)))))
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
       (should (string-match-p "failure" (agent-rig-tmux--run "capture-pane" "-p" "-t"
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
           (should-not (file-exists-p (expand-file-name "ALSO_NOT_CREATED" directory))))
       (delete-directory directory t)))))
