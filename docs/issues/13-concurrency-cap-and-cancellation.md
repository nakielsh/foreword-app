# 13 — Concurrency cap + queue + cancellation UI

## What to build

Replace single-flight from slice 07 with a real concurrency model.

Behavior:

- `ReviewOrchestrator` enforces a configurable concurrency cap (default 3, range 1–10, set in Settings via slice 06).
- A 4th (or N+1th) Review click goes into a FIFO queue. The PR card shows a "Queued (N ahead)" badge.
- Running reviews show a progress indicator and a cancel button; queued reviews show a cancel button that removes them from the queue without ever spawning.
- Cancelling a running review:
  - Kills the `Process` cleanly (SIGTERM, then SIGKILL after a short grace period).
  - Marks the review state `cancelled`.
  - Drops streamed text and does not persist any findings.
  - Keeps the worktree on disk for fast re-review.
- State machine: `queued → running → (completed | cancelled | failed | timeout)`.
- The modal sheet for a cancelled review shows "Cancelled" with whatever partial stream had accumulated, but no findings.

UI affordances:

- Per PR card, the Review button text changes based on state: `Review` / `Queued (N ahead)` / `Running...` / `Cancel`.
- A small global "in-flight reviews" indicator in the toolbar shows current running count and queue length.

## Acceptance criteria

- [ ] Cap defaults to 3, configurable 1–10 in Settings, change applies immediately.
- [ ] Review N+1 enters the queue with a visible "Queued (N ahead)" badge.
- [ ] Cancelling a queued review removes it without spawning anything.
- [ ] Cancelling a running review kills the process and reaches `cancelled` state cleanly.
- [ ] Worktree is preserved after cancellation.
- [ ] Cap of 1 results in strict serial execution; cap of N runs N concurrently.
- [ ] State machine transitions match: never goes `queued → completed` directly.
- [ ] Toolbar in-flight indicator updates live.

## Blocked by

- Issue 07 (Tracer bullet — end-to-end review)
