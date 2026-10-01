;; -*- lexical-binding: t; -*-
(require 'agent-rig-providers)

(defun agent-rig-worktree-start (team seat provider project directory branch)
  (interactive
   (let* ((project (agent-rig--directory))
          (provider (intern (completing-read "Provider: " agent-rig-providers nil t)))
          (team (read-string "Team: " nil nil agent-rig--last-team))
          (seat (read-string "Seat: " nil nil (symbol-name provider))))
     (list team seat provider project
           (read-directory-name "New worktree directory: " (file-name-directory
                                                          (directory-file-name project)))
           (read-string "New branch: " nil nil (concat "codex/" team "-" seat)))))
  (agent-rig--metadata team seat provider project)
  (agent-rig-provider-command provider)
  (when (or (file-remote-p directory) (file-exists-p directory))
    (user-error "Choose a new local worktree directory"))
  (when (or (not (stringp branch)) (string-prefix-p "-" branch))
    (user-error "Invalid branch name"))
  (let ((default-directory project)
        (directory (expand-file-name directory)))
    (with-temp-buffer
      (unless (zerop (process-file "git" nil t nil "check-ref-format" "--branch" branch))
        (user-error "Invalid branch: %s" (buffer-string)))
      (erase-buffer)
      (unless (zerop (process-file "git" nil t nil "worktree" "add" "-b" branch "--" directory "HEAD"))
        (user-error "Cannot create worktree: %s" (buffer-string))))
    (condition-case err
        (let ((id (agent-rig-start team seat provider directory)))
          (when (called-interactively-p 'interactive)
            (agent-rig-open (cl-find id (agent-rig-tmux-sessions)
                                     :key (lambda (item) (alist-get 'session item)) :test #'equal)))
          id)
      (error (user-error "Agent launch failed; worktree retained at %s: %s"
                         directory (error-message-string err))))))

(provide 'agent-rig-worktree)
