;; -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'subr-x)

(defvar agent-rig-providers
  '((codex :command ("codex"))
    (claude-code :command ("claude"))
    (opencode :command ("opencode"))))

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
