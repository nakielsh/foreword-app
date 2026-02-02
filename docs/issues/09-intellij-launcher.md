# 09 — IntelliJ launcher + finding click

## What to build

Make finding rows clickable to jump into IntelliJ at the right file and line.

`IntelliJLauncher` service:

- Public surface: `open(worktree: URL, file: String, line: Int)`.
- Spawns `idea --line <line> <worktree>/<file>` using the absolute path from `BinaryResolver` (`.idea`).
- Falls back to `open -a "IntelliJ IDEA" <worktree>/<file>` if `idea` CLI is missing. The fallback surfaces a non-blocking warning toast: "idea CLI not found — opened without line jump".
- Always passes the worktree root as the project context so IntelliJ indexes the worktree (not the user's main repo checkout). First open per worktree is slow due to indexing — that is expected.

UI wiring:

- Clicking a finding row in the modal (slice 08) calls `IntelliJLauncher.open(worktreePath, finding.file, finding.line)`.
- A small "open in IntelliJ" icon button on the row provides the same action with a clear affordance.

## Acceptance criteria

- [ ] Clicking a finding row launches IntelliJ at the worktree, jumping to file:line.
- [ ] The IntelliJ project is the worktree, not the user's main repo checkout.
- [ ] When `idea` CLI is missing, fallback opens the file without line jump and shows a warning toast.
- [ ] When the file path no longer exists in the worktree (e.g. claude hallucinated a path), surface a clear error rather than crashing.
- [ ] Per-row icon button works identically to clicking the row.

## Blocked by

- Issue 08 (Findings UI)
