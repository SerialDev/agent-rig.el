;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'subr-x)

(defvar agent-rig-providers
  '((codex :command ("codex") :resume ("resume") :compact "/compact")
    (claude-code :command ("claude") :resume ("--resume") :compact "/compact")
    (opencode :command ("opencode" "--hostname" "127.0.0.1" "--port" "0") :resume ("--session") :compact "/compact")))

(defun agent-rig-provider-resume-command (provider conversation)
  (unless (and (stringp conversation)
               (string-match-p "\\`[A-Za-z0-9][A-Za-z0-9_-]*\\'" conversation))
    (user-error "Enter an explicit provider conversation ID"))
  (let ((arguments (plist-get (alist-get provider agent-rig-providers) :resume)))
    (unless (and (consp arguments) (cl-every #'stringp arguments))
      (user-error "Provider %s has no resume command configured" provider))
    (append (agent-rig-provider-command provider) arguments (list conversation))))

(defun agent-rig-provider-command (provider)
  (let* ((spec (alist-get provider agent-rig-providers))
         (command (plist-get spec :command)))
    (unless (and (consp command) (cl-every #'stringp command)
                 (not (string-empty-p (car command))))
      (user-error "Unknown or invalid provider: %s" provider))
    (let ((executable (executable-find (car command))))
      (unless executable
        (user-error "Cannot find %s in Emacs exec-path" (car command)))
      (cons executable (cdr command)))))

(defun agent-rig-provider-candidates ()
  (mapcar
   (lambda (entry)
     (let* ((provider (car entry))
            (spec (cdr entry))
            (command (plist-get spec :command))
            (program (car-safe command))
            (executable (and (stringp program) (executable-find program))))
       (cons (format "%s  [%s]  resume: %s\n    %s\n    Activity: %s"
                     provider (if executable "installed" "missing executable")
                     (if (plist-get spec :resume) "yes" "unconfigured")
                     (mapconcat #'shell-quote-argument command " ")
                     (pcase provider
                       ('codex "native status, recent tools, child agents (conversation ID required)")
                       ('claude-code "native status, observed child events on new launches")
                       ('opencode "loopback API status, recent tools, direct children (conversation ID required)")
                       (_ "terminal and operating-system processes")))
             provider)))
   agent-rig-providers))

(defun agent-rig-read-provider (&optional prompt)
  (let* ((candidates (agent-rig-provider-candidates))
         (prompt (or prompt "Provider: "))
         (selected
          (if (require 'helm nil t)
              (helm :sources `(((name . "Agent Rig providers")
                                (candidates . ,candidates)
                                (multiline)
                                (action . identity)))
                    :buffer "*Helm Agent Rig Providers*" :prompt prompt)
            (cdr (assoc (completing-read prompt candidates nil t) candidates)))))
    (unless selected (user-error "No provider selected"))
    selected))

(provide 'agent-rig-providers)
