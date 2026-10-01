;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'subr-x)

(defvar agent-rig-providers
  '((codex :command ("codex") :resume ("resume"))
    (claude-code :command ("claude") :resume ("--resume"))
    (opencode :command ("opencode") :resume ("--session"))))

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

(provide 'agent-rig-providers)
