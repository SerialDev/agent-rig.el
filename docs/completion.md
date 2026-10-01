# Completion requirements

Objective: a fully functional native Emacs equivalent of the core OpenRig workflow, with usability and integration into Tiqsi's init-lite configuration at the forefront. This checklist tracks unfinished work; passing a narrower suite does not establish completion.

| Requirement | Current evidence | Remaining verification or implementation |
| --- | --- | --- |
| Public standalone package, sibling checkout, Straight installation | Published repository, package PR #1, Tiqsi PR #3; live integration loaded through Straight | Keep both working trees and PRs synchronized through completion |
| Named teams and seats across Codex, Claude Code, OpenCode, and configurable CLIs | Real tmux lifecycle and provider validation in CI | Complete live launch and attachment inspection for all three providers |
| Reliable discovery, exit status, terminal history, reattachment | Cross-process discovery and immediate-exit history in CI | Confirm closing/reopening an actual vterm client preserves its agent |
| Native Tiqsi workflow | Live dashboard, Codex vterm, Hydra menu, and explicit return-to-code inspected; module CI passes | Complete narrow/wide layout and context-composition inspection |
| Context and communication | Region/buffer/diff composition, project-scoped broadcast, partial retry, literal Unicode paste in CI | Add deliberate submission and useful agent-to-agent handoff without conflating paste with acknowledged execution |
| Persistent teams and provider conversation continuity | Live sessions survive Emacs restart | Implement disk snapshots, restoration after tmux shutdown, explicit native conversation resume, and clear per-seat outcomes |
| Existing-session adoption | No implementation | Add discovery/adoption that preserves existing process and provider state |
| Project isolation for concurrent work | Teams are distinguished by canonical project path | Integrate optional Git worktrees without implicit checkout or destructive cleanup |
| Operational visibility and recovery | Process state, output capture, runtime help, and error diagnostics | Persist useful lifecycle outcomes and make recovery actions discoverable |
| Verified delivery | Package CI on distribution tmux and 3.7c, separate Tiqsi integration CI | Inspect final-head CI and full workflow evidence, update installation/use documentation, leave no required work unverified |

The native Codex terminal currently presents its hook-review screen. Inspection has not changed that trust decision. Authentication, hook trust, and provider approvals remain provider-owned interactions.
