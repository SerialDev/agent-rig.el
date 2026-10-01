# Agent Rig

Manage Codex, Claude Code, OpenCode, and other terminal agents from Emacs. Inspired by [OpenRig](https://github.com/mvschwarz/openrig), with orchestration implemented in Emacs Lisp and tmux keeping agent processes alive independently of Emacs.

This initial release provides project-scoped teams, named seats, a dashboard, interactive terminals, prompt composition, team broadcasts, output capture, and rediscovery after restarting Emacs. It does not depend on OpenRig or its daemon.

## Install

Requires Emacs 27.1 or newer, tmux 3.7 or newer for the complete workflow, and at least one installed and authenticated agent CLI. Older tmux versions support session management and direct terminal input, but cannot report the readiness needed for buffered prompt delivery. On macOS, install tmux with `brew install tmux`. Ensure CLI executables are visible in Emacs `exec-path`, including `~/.local/bin` if Claude is installed there.

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

The dashboard opens beside your code, keeps the originating project, and refreshes while visible. Press `a` to include other projects, or open with `C-u M-x agent-rig` to show all projects initially. In Tiqsi, `C-c A` opens the agent hydra, using the same hydra and completion conventions as the rest of the configuration. Press `?` in the dashboard for commands and executable diagnostics.

| Key | Action |
| --- | --- |
| `n` | Launch an agent in a named team and seat |
| `t` | Launch a team template |
| `RET` | Open or reattach the selected agent terminal |
| `TAB` | Choose another agent through completion |
| `s` | Compose a prompt for the selected agent |
| `b` | Compose a broadcast to running seats in the same team and project |
| `o` | Capture up to 2,000 lines of terminal output |
| `r` | Restart an exited agent with a fresh conversation |
| `k` | Stop a session and discard its terminal history, after confirmation |
| `g` | Refresh discovery and process status |
| `a` | Toggle current project and all projects |
| `?` | Show commands and runtime diagnostics |

In a prompt buffer, `C-c C-c` pastes the draft into its targets. Submit it from each agent's own terminal. Delivery requires bracketed paste support, so onboarding or an unready terminal produces an actionable error instead of receiving raw keystrokes. Successfully pasted targets are removed from the pending list; a failed broadcast can be retried without duplicating successful deliveries. Region prompts use `M-x agent-rig-send-region`.

Agent Rig uses vterm when installed, as in Tiqsi, and falls back to built-in `term`. Terminal names include the project, team, and seat. Existing Tiqsi navigation bindings remain available. Inside an agent terminal, `C-c a` returns to the dashboard, `C-c C-s` composes a prompt, `C-c C-n` selects the next agent in this project, and `C-c C-o` returns to your source window. Tiqsi also exposes `C-c A` there. In the fallback terminal, use `C-c C-j` for line mode and `C-c C-k` for character mode. Closing a terminal buffer detaches the client; it does not stop the agent. You can also attach outside Emacs with `tmux -L agent-rig attach`.

`agent-rig-send-region` and `agent-rig-send-buffer` include the file name, line range, and whether the buffer has unsaved changes. `agent-rig-send-diff` composes the tracked working-tree diff against HEAD, including staged and unstaged tracked changes. Untracked files are excluded. All context remains editable in the prompt buffer before delivery.

Panels use the bottom of narrow frames and the right of wide frames, keeping source windows available. Set `agent-rig-display-buffer-action` to an Emacs display action to override that placement, and `agent-rig-refresh-interval` to a positive number of seconds or nil to disable automatic refresh. `agent-rig-terminal-function` accepts a session alist and can be set to `agent-rig-vterm`, `agent-rig-term`, or a custom terminal adapter.

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

All three modules are delivered by one Straight recipe. The package requires built-in Emacs libraries; vterm is an optional integration.

## Development

CI runs ERT against both the distribution tmux and tmux 3.7c, using disposable shell fixtures. It covers project isolation, duplicate seats, preflight validation, metadata errors, immediate process exits, cross-process discovery, literal command arguments, multiline Unicode paste on 3.7c, the older-version diagnostic, and partial-delivery retries. Dashboard, context, keymap, prompt-buffer, and timer lifecycle tests cover the Emacs workflows. The Tiqsi repository separately exercises the actual integration module with Hydra. CI does not invoke paid agent services.

To explicitly run the suite locally:

```sh
emacs -Q --batch -L . -l test/agent-rig-test.el -f ert-run-tests-batch-and-exit
```

### Recovery

From the dashboard, `i` records the exact native conversation ID for the selected seat. `S` saves all seats in the current project; `R` restores a snapshot. Existing seats are left untouched. Seats with an ID request the provider's native resume command; seats without an ID start fresh after confirmation. Resume is reported as requested, not as verified continuity: inspect the provider terminal for its result.

Snapshots contain project paths, seat identities, providers, and optional conversation IDs, never executable commands. They are written atomically with mode 0600 under `agent-rig-state-directory` (default `~/.emacs.d/agent-rig/`). Restoration validates the whole snapshot before launching anything, reports each seat separately, and retains the latest results in `last-restore.json`. It does not replay prompts or restore unsent provider input.

In an agent terminal, `C-c C-d` detaches the Emacs client while leaving the agent alive. Use `C-c a` to reach Emacs commands through the dashboard; terminal modes can forward ordinary Emacs shortcuts to the provider.

### Collaboration and isolation

Dashboard `h` creates an editable handoff containing another agent's captured terminal output. Choose the recipient, write its task, and trim the capture before `C-c C-c` pastes it. In a terminal, `C-c C-j` explicitly sends Enter after confirmation; the provider still owns acceptance and approval. No delivery is reported as completed model work.

Dashboard `w` creates a new Git branch and worktree at a new directory, then launches the agent there. The original checkout is untouched. Existing directories and branches are rejected by preflight/Git; a launch failure retains the created worktree and reports its path. Stopping an agent never removes its worktree.

Dashboard `A` adopts an unmanaged, running, single-pane/single-window session on `agent-rig-tmux-socket`. Select the terminal and identify its provider. Adoption adds manager metadata and retains terminal output on process exit; it does not restart the process. Use `agent-rig-tmux-socket` consistently for one server (default `agent-rig`; `default` selects the usual tmux server). Cross-server aggregation and attaching non-tmux processes are not supported. Existing multi-pane sessions are excluded so the manager cannot take over an unrelated workspace.

Dashboard `f`, or `C-c C-f` inside a terminal, toggles the agent to a full-frame view and restores the previous window layout. `C-c C-o` also restores that layout before returning to code.
