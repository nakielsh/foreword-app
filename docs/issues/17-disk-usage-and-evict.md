# 17 — Disk usage view + per-repo cache evict

## What to build

A Settings section that shows disk usage of the app's local caches and lets the user free space.

`WorktreeManager` extension:

- `diskUsage() -> Bytes` — sums sizes of `~/.work-homepage/repos/` (bare clones) and `~/.work-homepage/worktrees/` (live worktrees).
- `usagePerRepo() -> [(repo, bareBytes, worktreeBytes)]` — per-repo breakdown.
- `evictAllForRepo(repo)` — removes both the bare clone and all worktrees for a given repo. Refuses if any review is currently running against that repo (surface clear error).

Settings view:

- Total disk usage line at top.
- Table listing each repo with bare-clone size, total worktree size, and a per-repo "Evict" button.
- Confirmation dialog before evicting.
- "Refresh" button recomputes sizes (computing sizes is I/O-heavy, do not do it on every view render).

## Acceptance criteria

- [ ] Settings shows accurate total disk usage.
- [ ] Per-repo breakdown matches actual filesystem state.
- [ ] Evict-per-repo removes both bare clone and worktrees, after confirmation.
- [ ] Evict refuses (with clear message) if a review is running against that repo.
- [ ] "Refresh" recomputes sizes; sizes do not auto-update on every render.
- [ ] Re-reviewing a PR for an evicted repo re-clones cleanly.

## Blocked by

- Issue 06 (BinaryResolver + first-run wizard)
- Issue 07 (Tracer bullet — end-to-end review)
