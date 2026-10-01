# Agent Rig

Manage Codex, Claude Code, OpenCode, and other terminal agents from Emacs. Inspired by [OpenRig](https://github.com/mvschwarz/openrig), with native Emacs Lisp orchestration and tmux keeping agents alive independently of the editor. No OpenRig daemon is required.

## Install

Requires Emacs 27.1+, tmux 3.7+ for buffered prompt delivery, and installed/authenticated provider CLIs visible in Emacs `exec-path`. Older tmux versions support lifecycle management and direct terminal input. On macOS, install tmux with `brew install tmux`.

```elisp
(use-package agent-rig
  :straight (agent-rig :type git :host github
                       :repo "SerialDev/agent-rig.el"
                       :branch "codex/native-agent-manager"
                       :files ("*.el"))
  :commands (agent-rig agent-rig-start agent-rig-start-team agent-rig-send-region)
  :bind (("C-c a" . agent-rig)))
```

The implementation branch is explicit while the initial PR is under review. After merging, change the recipe to `:branch "main"`. Add `:local-repo "/absolute/path/to/agent-rig.el"` for an editable checkout. Tiqsi's init-lite module automatically uses a sibling checkout when present, otherwise GitHub. After adding modules to an existing local checkout, run `M-x straight-rebuild-package RET agent-rig`.

## Emacs workflow

Open `M-x agent-rig` in a project. Tiqsi binds `C-c a` to the dashboard and `C-c A` to its agent Hydra, including inside agent terminals. Providers retain their own authentication, configuration, hook trust, and approvals.

The dashboard follows the originating project and refreshes only while visible. Its highlighted row is the action target; `j`/`k`, arrows, or `C-n`/`C-p` move between agents. Grouped clickable actions and selected-seat details appear beneath the list. `?` opens a native action menu: press a displayed key or click an action, and it runs against the original selection. `q` or Escape closes that menu.

Panels appear below code in narrow frames and to the right in wide frames. `f` expands an agent view to the full frame and restores the previous layout. Override placement with `agent-rig-display-buffer-action`; disable idle refresh by setting `agent-rig-refresh-interval` to nil.

| Dashboard key | Action |
| --- | --- |
| `n`, `t` | Launch one agent or a team template |
| `RET`, `TAB` | Attach selected agent or choose another |
| `s`, `b` | Compose a prompt or same-project/team broadcast |
| `h` | Compose an editable handoff to another agent |
| `o` | Capture up to 2,000 terminal history lines |
| `w` | Launch in a new branch and Git worktree |
| `A` | Adopt an existing standalone tmux terminal |
| `i`, `S`, `R` | Record conversation ID, save project seats, restore snapshot |
| `r`, `x` | Restart exited seat fresh, or stop selected pane after confirmation |
| `a`, `g`, `?` | Toggle all projects, refresh, show commands and runtime diagnostics |
| `f`, `C-c C-o` | Toggle full frame, return to source window |

Agent Rig prefers vterm, retaining Tiqsi's terminal navigation, and falls back to built-in term. Closing a terminal buffer detaches its client without stopping the agent. `agent-rig-terminal-function` can select either adapter or a custom function accepting a session alist.

| Terminal key | Action |
| --- | --- |
| `C-c a`, `C-c C-s` | Dashboard, compose prompt |
| `C-c C-o`, `C-c C-n` | Return to code, next agent in this project |
| `C-c C-f`, `C-c C-d` | Toggle full frame, detach |
| `C-c C-j` | Send Enter to visible provider input after confirmation |

Use these bindings or return to the dashboard before invoking Emacs commands: terminal modes may forward ordinary editor shortcuts to the provider. Agent Rig reserves the listed terminal bindings, including `C-c C-j` in the term fallback.

## Context and communication

`agent-rig-send-region` and `agent-rig-send-buffer` include file name, line range, and unsaved-buffer status. `agent-rig-send-diff` includes staged and unstaged tracked changes against HEAD, excluding untracked files. Handoffs include source identity and captured output with a space to write the recipient's task. Review and trim all context in the editable prompt buffer.

`C-c C-c` pastes a draft without submitting it. Then submit from the provider terminal, using its normal input or `C-c C-j`. Finish startup and choose the intended input field first. Bracketed-paste support is required; it is not proof that a provider is idle or that a model accepted work. Successfully pasted broadcast targets are removed from pending deliveries, so retries do not duplicate successful pastes.

## Teams and providers

The `pair` template starts a Codex implementer and Claude Code reviewer. `mixed` adds an OpenCode explorer. Customize templates and CLI arguments:

```elisp
(setq agent-rig-teams
      '(("feature" ("builder" codex) ("reviewer" claude-code))))
(setq agent-rig-providers
      '((codex :command ("codex") :resume ("resume"))
        (claude-code :command ("claude") :resume ("--resume"))
        (opencode :command ("opencode") :resume ("--session"))
        (custom :command ("my-agent" "--interactive"))))
```

Arguments are literal strings, not shell fragments. Preflight validates every team member before launch; a launch failure removes only sessions started by that attempt. Seat identity combines team, seat, and canonical project directory. Team members share their selected directory. Worktree launch creates a new branch/directory from HEAD without switching the source checkout; existing paths/branches are rejected. A provider launch failure retains the worktree and reports its path. Stopping an agent never deletes worktrees.

## Persistence and recovery

Processes and terminal history survive Emacs closure while tmux remains running. Save a project's seats with `S` for recovery after tmux shutdown or reboot. Snapshots are versioned JSON written atomically with mode 0600 under `agent-rig-state-directory`, defaulting to `agent-rig/` inside `user-emacs-directory`. They contain identities, paths, providers, and optional conversation IDs, never executable commands or prompt text.

Use `i` to record the exact native conversation ID. Restore validates the entire snapshot, leaves existing seats untouched, and reports each seat separately. Seats with IDs request provider-native resume; others start fresh after confirmation. Resume is reported as requested until verified in the provider terminal. The latest restore outcomes are retained in `last-restore.json`. Snapshots do not preserve unsent terminal input or replay messages.

The dedicated `agent-rig` tmux server starts without loading user tmux configuration. Adoption discovers unmanaged running single-pane/single-window sessions on the configured `agent-rig-tmux-socket`. It records metadata and enables retained exit output without restarting the process. Use one socket consistently; `"default"` selects the usual tmux server. Cross-server aggregation, adopting multi-pane workspaces, and retroactive attachment of non-tmux processes are unsupported.

The dashboard reports process state and exit code, not inferred agent progress or task success. Automatic conversation discovery, task dependency scheduling, autonomous routing, usage telemetry, and an MCP control API are outside this release.

## Modules and validation

| Module | Responsibility |
| --- | --- |
| `agent-rig.el` | Dashboard, terminals, teams, prompts, handoffs |
| `agent-rig-providers.el` | Executable validation and explicit resume arguments |
| `agent-rig-tmux.el` | Lifecycle transport, metadata, discovery, bracketed paste |
| `agent-rig-state.el` | Snapshots, validation, restoration outcomes |
| `agent-rig-worktree.el` | Explicit isolated checkout launches |

One Straight recipe delivers all modules. CI runs ERT on distribution tmux and tmux 3.7c, using disposable shell fixtures rather than paid agents. Coverage includes lifecycle/exit history, cross-process discovery, literal arguments, Unicode paste, partial retries, recovery after server loss, adoption without process replacement, worktree isolation, and window restoration. Tiqsi separately tests its actual integration module with Hydra.

For explicitly requested local validation:

```sh
emacs -Q --batch -L . -l test/agent-rig-test.el -f ert-run-tests-batch-and-exit
```
