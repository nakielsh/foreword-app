# 15 — PR close → drop reviews + worktree, manual evict

## What to build

When a PR is closed or merged, drop its worktree and all `Review` / `Finding` rows. Provide a manual evict button per PR for explicit cleanup.

Behavior:

- After every Reviews-tab refresh, the orchestrator inspects each PR's state from the GitHub response. For any PR that transitioned from open to `closed` or `merged` since last refresh:
  - Call `WorktreeManager.evict(repo, prNumber)` — removes the worktree but keeps the bare clone.
  - Call `ReviewStore.dropForPR(prKey)` — removes all `Review` and `Finding` rows for that PR.
- Per PR card, a small "Evict" menu item (in a context menu or kebab menu) lets the user manually trigger the same cleanup for an open PR. Confirms via dialog before acting.
- Bare clones are NOT dropped automatically here — they are reused across PRs and managed via slice 17 (per-repo evict) or `WorktreeManager.evictAllForRepo`.

## Acceptance criteria

- [ ] On Reviews-tab refresh, closed/merged PRs trigger automatic worktree + reviews drop.
- [ ] User-facing notification confirms the drop (single toast: "Cleaned up N closed PRs").
- [ ] Manual "Evict" menu on an open PR card removes worktree + reviews after confirmation.
- [ ] Bare clones survive these drops.
- [ ] Re-reviewing a previously-evicted PR re-creates the worktree from the bare clone correctly.

## Blocked by

- Issue 07 (Tracer bullet — end-to-end review)
