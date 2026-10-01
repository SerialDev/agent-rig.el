# Agent Rig

Manage Codex, Claude Code, OpenCode, and other terminal agents from Emacs. Inspired by [OpenRig](https://github.com/mvschwarz/openrig), with native Emacs Lisp orchestration and tmux keeping agents alive independently of the editor. No OpenRig daemon is required.

## Install

Requires Emacs 27.1+, tmux 3.7+ for buffered prompt delivery, and installed/authenticated provider CLIs visible in Emacs `exec-path`. Older tmux versions support lifecycle management and direct terminal input. On macOS, install tmux with `brew install tmux`.

```elisp
(straight-use-package 'websocket)
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

The dashboard follows the originating project and refreshes only while visible. Its highlighted row is the action target; `j`/`k`, arrows, or `C-n`/`C-p` move between agents. A workspace summary, process-status marks, selected-agent card, and persistent shortcut bar keep context visible. `/` filters by team, seat, provider, or path; Escape clears the filter. `:` opens a command picker through your normal Emacs completion UI.

`?` opens bordered action groups with distinct key labels, laid out in two columns or stacked in narrow windows. Press a displayed key or click an action to run it against the original selection; `q` or Escape returns. This presentation takes inspiration from [OpenRig's TUI](https://github.com/mvschwarz/openrig/tree/main/packages/tui), particularly its explorer/detail hierarchy, semantic color roles, and command palette. Rendering remains native Emacs text, faces, buttons, and windows. The `agent-rig-*` faces support dark/light themes and terminal Emacs.

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

The dashboard reports process state, exit code, and verified native activity when available. Native activity does not establish task success. Automatic conversation discovery, task dependency scheduling, autonomous routing, usage telemetry, and an MCP control API are outside this release.

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

### Agent navigation and activity

`M-left` returns from an agent terminal or activity view to the all-projects overview, clears any filter, and keeps that agent selected. `M-right` opens the selected agent terminal. Neither action stops the agent.

Press `d` for the activity inspector: foreground command, pane PID, OS descendant processes with CPU and elapsed time, and recent terminal output. The visible inspector refreshes every three seconds; `g` refreshes immediately. Claude Code's native session status is queried asynchronously and matched by exact PID. Unsupported CLI versions or missing sessions report unavailable. OS children are not counted as subagents; shared daemons and in-process agent work cannot be inferred from a process tree. New Claude seats use the session-only observer described below. Codex and OpenCode native activity require an explicitly recorded conversation ID, as described below.

The overview's State column shows Claude's native `idle`, `busy`, `waiting`, or `shell` state when a local session record matches the pane PID, working directory, and current process lifetime. `waiting` is highlighted. Exited panes always remain exited. Missing or incompatible records fall back to process state in the overview and the asynchronous CLI probe in the inspector. `CLAUDE_CONFIG_DIR` is honored when present in Emacs's environment.

### Codex native activity

Install the optional `websocket` Emacs package (Tiqsi's integration does this through Straight). In the Codex seat, use `i` to record the exact conversation ID shown by Codex. Open `d` to inspect that recorded conversation: native status and approval/input flags, loaded spawned descendants with their roles and native statuses, and tools among the ten most recent native items. The conversation's project must match the seat's project.

This connection reads the existing daemon's Unix control socket, without starting a daemon, resuming a conversation, submitting prompts, or answering approval requests. The default socket is under `CODEX_HOME` or `~/.codex`; set `agent-rig-codex-socket` for another existing daemon. Requests have a ten-second deadline. Missing sockets, missing dependencies, unsupported protocol methods, and inventories exceeding 1,000 records report unavailable.

The recorded conversation is shown separately from the terminal process. Its ID is user supplied, not inferred from a PID or the most recent project conversation. Update it after switching conversations inside Codex. `notLoaded` means the recorded conversation is not loaded in that daemon. The child view follows native parent IDs, excludes unloaded children, and includes nested spawned descendants; OS subprocesses remain a separate section.

### OpenCode native activity

New default OpenCode seats use `--hostname 127.0.0.1 --port 0`, enabling OpenCode's local HTTP API on an automatically chosen port. Existing seats and custom provider commands are unchanged. Preserve these flags in a custom command to use this adapter. OpenCode's API offers control operations, but Agent Rig makes GET requests only. It does not bind to external network interfaces or enable mDNS.

Record the exact session ID with `i`, then open `d`. With `curl` and `lsof` on Emacs's `exec-path`, the inspector discovers IPv4 loopback listeners owned by the running pane PID, verifies OpenCode's health endpoint and the recorded session's project, and reads native busy/idle/retry status, direct child sessions, and tools from the ten most recent messages. Child sessions from a different directory report unavailable status. An absent entry in OpenCode's status map means idle, matching its native status implementation; it does not prove that the conversation is selected in the TUI.

If the server uses `OPENCODE_SERVER_PASSWORD`, keep that value and optional `OPENCODE_SERVER_USERNAME` available in Emacs's environment. Credentials travel through curl's standard input, not its command arguments. The adapter disables curl configuration files and proxies, follows no redirects, limits responses to 1 MiB, and bounds the snapshot to ten seconds. Missing APIs or malformed status responses report unavailable. The default OpenCode 1.16.2 TUI does not expose this API without explicit network flags, so older running seats need a deliberate new launch before native inspection is available.

### Provider selection and lifecycle

Creation, adoption, worktree launches, and new handoff recipients share a provider picker. Helm is used when installed; otherwise standard completion is used. Candidates show executable availability, literal launch arguments, resume support, and activity capabilities. Missing executables remain visible and launch preflight reports the missing program. Configure CLI arguments in `agent-rig-providers`; model and account selection remain in the native provider.

In rig mode, `n` creates an agent, `x` removes its tmux pane and terminal history after confirmation, and `c` composes the provider's `/compact` command. Compaction uses the normal draft/paste/explicit-submit flow; inspect the provider input and result. It does not clear or replace a conversation. Custom providers can configure `:compact`.

`h` selects a running recipient or creates a new seat in the source workspace. The editable handoff includes source/recipient paths, objective, decisions, remaining work, relevant files, and a bounded terminal excerpt. Review and trim it before sending. This transfers text context across providers, not hidden reasoning or native session state. Removal leaves worktrees, provider conversation storage, and saved seat snapshots intact; restoring an older snapshot can recreate a removed seat.

### Claude child observations

New Claude launches append a session-only plugin that records SessionStart/SessionEnd and SubagentStart/SubagentStop events without changing user or project settings. Existing seats need a fresh launch to gain the observer. Records contain only native session ID, agent ID, role, event, and observation time, stored privately under `agent-rig-claude-observer-directory`. Set `agent-rig-claude-observe-subagents` to nil to disable it for subsequent launches.

The inspector associates events only with the verified native session. It labels child events “start observed” and “stop observed”; these are lifecycle observations, not proof of task success. Resuming a child replaces its previous stop observation. Disabled hooks, missing session markers, and unreadable records report unavailable. Removal and restart clean the seat's observer directory. Snapshot files exclude ephemeral observer identifiers.
