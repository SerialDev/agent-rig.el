# Agent Rig

Manage Codex, Claude Code, OpenCode, and other terminal agents from Emacs. Inspired by [OpenRig](https://github.com/mvschwarz/openrig), with orchestration implemented in Emacs Lisp and tmux keeping agent processes alive independently of Emacs.

This initial release provides project-scoped teams, named seats, a dashboard, interactive terminals, prompt composition, team broadcasts, output capture, and rediscovery after restarting Emacs. It does not depend on OpenRig or its daemon.

## Install

Requires Emacs 27.1 or newer, tmux 3.2 or newer, and at least one installed and authenticated agent CLI. On macOS, install tmux with `brew install tmux`. Ensure CLI executables are visible in Emacs `exec-path`, including `~/.local/bin` if Claude is installed there.

With Straight and use-package:

```elisp
(use-package agent-rig
  :straight (agent-rig :type git :host github
                       :repo "SerialDev/agent-rig.el"
                       :branch "codex/native-agent-manager"
                       :files ("*.el"))
  :commands (agent-rig agent-rig-start agent-rig-start-team agent-rig-send-region)
  :bind (("C-c a" . agent-rig)))
```

The implementation branch is explicit while the initial pull request is under review. After merging, change the recipe to `:branch "main"`.

For an editable sibling checkout, add `:local-repo "/absolute/path/to/agent-rig.el"` to that same recipe. Straight builds directly from that checkout; there is no second package copy to keep synchronized. `tiqsi-emacs`'s `init-lite.el` integration automatically chooses a sibling checkout if it exists, otherwise it clones from GitHub.

## Use

Run `M-x agent-rig` or `C-c a` in Tiqsi. Press `n` to launch one agent, or `t` to launch a team template in a project directory. The `pair` template starts a Codex implementer and Claude Code reviewer; `mixed` also starts an OpenCode explorer. Each provider keeps its normal authentication, configuration, and approval behavior.

| Key | Action |
| --- | --- |
| `n` | Launch an agent in a named team and seat |
| `t` | Launch a team template |
| `RET` | Open or reattach the selected agent terminal |
| `s` | Compose a prompt for the selected agent |
| `b` | Compose a broadcast to running seats in the same team and project |
| `o` | Capture up to 2,000 lines of terminal output |
| `r` | Restart an exited agent with a fresh conversation |
| `k` | Stop a session and discard its terminal history, after confirmation |
| `g` | Refresh discovery and process status |

In a prompt buffer, `C-c C-c` pastes the draft into its targets. Submit it from each agent's own terminal. Delivery requires bracketed paste support, so onboarding or an unready terminal produces an actionable error instead of receiving raw keystrokes. Successfully pasted targets are removed from the pending list; a failed broadcast can be retried without duplicating successful deliveries. Region prompts use `M-x agent-rig-send-region`.

The default terminal is Emacs's built-in `term`. Use `C-c C-j` for line mode and `C-c C-k` for character mode. Closing this buffer detaches the client; it does not stop the agent. You can also attach outside Emacs with `tmux -L agent-rig attach`. For richer terminal rendering, set `agent-rig-terminal-function` to a function accepting a session alist and opening your preferred terminal attached to its `session` field on `agent-rig-tmux-socket`.

## Teams and providers

```elisp
(setq agent-rig-teams
      '(("feature" ("builder" codex) ("reviewer" claude-code)
                   ("researcher" opencode))))

(setq agent-rig-providers
      '((codex :command ("codex"))
        (claude-code :command ("claude"))
        (opencode :command ("opencode"))
        (custom :command ("my-agent" "--interactive"))))
```

A provider is an executable plus literal arguments, not a shell fragment. Agent Rig resolves the executable through `exec-path` before launching. Team validation checks every provider and directory before starting any member. A launch failure removes only the sessions started by that launch attempt. Teams in different canonical project directories have independent identities. Seats in a team share the selected working directory; create Git worktrees yourself when concurrent edits need isolation.

## State and boundaries

The `agent-rig` tmux socket is dedicated to this package and starts without loading your tmux configuration. Metadata is versioned JSON stored as a tmux pane option. Discovery reads that metadata without evaluating Lisp. No agent settings, trust entries, permission flags, or startup files are rewritten.

Live processes and terminal history survive closing Emacs while the tmux server remains running. They do not survive a machine reboot or server shutdown. Restarting an exited seat launches its original command; it does not resume a provider conversation. Provider-specific conversation discovery, adoption of existing outside sessions, native resume IDs, task dependency graphs, automatic agent-to-agent routing, reboot snapshots, worktree orchestration, usage telemetry, and MCP control are not implemented in this initial release.

The dashboard reports process liveness and exit codes, not inferred agent progress, readiness, or task success. Prompt pasting is a terminal operation, not an acknowledged provider message API. Finish startup and choose an appropriate input field before pasting. Broadcast delivery is sequential and may partially succeed; the prompt buffer retains only undelivered targets.

## Modules

| Module | Responsibility |
| --- | --- |
| `agent-rig.el` | Team lifecycle, project selection, dashboard, terminals, prompt buffers |
| `agent-rig-providers.el` | Provider command definitions and executable validation |
| `agent-rig-tmux.el` | Process transport, metadata discovery, literal bracketed paste |

All three modules are delivered by one Straight recipe. The package uses built-in Emacs libraries only.

## Development

CI runs ERT against a real tmux server and disposable shell fixtures. It covers project isolation, duplicate seats, preflight validation, metadata errors, immediate process exits, cross-process discovery, literal command arguments, multiline Unicode paste, and partial-delivery retries. It does not invoke paid agent services.

To explicitly run the suite locally:

```sh
emacs -Q --batch -L . -l test/agent-rig-test.el -f ert-run-tests-batch-and-exit
```
