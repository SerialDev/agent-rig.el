# Delivery evidence

Objective: native Emacs management of terminal agents with Tiqsi init-lite integration. The supported workflow and explicit boundaries are defined in [README.md](../README.md).

| Requirement | Evidence |
| --- | --- |
| Public standalone package and Straight integration | SerialDev/agent-rig.el, package PR #1, Tiqsi PR #3; sibling checkout loaded and rebuilt through Straight in live Emacs |
| Codex, Claude Code, OpenCode terminals | All three native CLIs launched and attached through vterm in the user's Emacs |
| Detach and reattach | Codex terminal client closed and reopened while its tmux process remained running |
| Tiqsi usability | Hydra menu, project dashboard, narrow bottom panel, full-frame toggle and restored source layout inspected live; adaptive wide-frame placement covered in ERT |
| Context and communication | Live editable prompt pasted to OpenCode and Claude; explicit Claude submission produced “Agent Rig ready”; context, partial retries, Unicode paste, handoff composition covered in ERT |
| Recovery | Versioned private snapshots, explicit provider resume IDs, whole-file validation, per-seat outcomes; CI kills a disposable tmux server and verifies idempotent restoration |
| Existing-session adoption | Standalone same-socket adoption verified in CI with unchanged process PID; multi-pane and non-tmux processes excluded |
| Worktree isolation | CI creates a separate branch/worktree and verifies the source checkout remains on its original branch |
| Operational boundaries | No native provider settings or permissions rewritten; process state distinguished from provider task completion |
| Validation | Package ERT matrix on distribution tmux and 3.7c; separate Tiqsi integration ERT with Hydra; syntax and whitespace checks locally, no local test suites |

OpenCode accepted the live prompt but its configured provider returned a billing-related error. Agent Rig cannot establish successful model output until that account-side condition is resolved. Native conversation resume is implemented with explicit user-supplied IDs; the manager reports a request, not verified provider continuity. No real provider process was killed to test restoration: server-loss coverage uses disposable CI fixtures.

The activity inspector adds exact-PID Claude status, foreground commands, descendant process snapshots, and terminal output. Meta-arrow navigation connects overview, terminal, and activity views. Regression coverage checks PID association, descendant isolation, and key bindings. Native Codex/OpenCode activity and subagent telemetry remain unsupported rather than being inferred from process existence.
