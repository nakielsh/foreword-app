# 14 — Review versioning + history view

## What to build

Each new commit on a PR produces a new `Review` row keyed on `(prKey, headSha)`. Old reviews are kept and visible.

Behavior:

- When the user clicks Review on a PR, the orchestrator first fetches the current head SHA. If a `Review` row exists for `(prKey, currentSha)`, the modal opens that existing review (no new run unless explicitly asked). If not, a new `Review` row is created and a new run starts.
- A "Re-review" button inside the modal forces a new run against the current head SHA, even if a row for that SHA already exists. New row is added.
- The modal includes a "History" disclosure listing prior reviews for the same PR, sorted newest-first by `headSha` timestamp. Each entry shows verdict, summary, finding count, and timestamp; clicking switches the modal to that historical review.
- The latest review for a PR is what the PR card surfaces (verdict badge etc.).

## Acceptance criteria

- [ ] Re-running a review against a new SHA creates a new `Review` row, preserves the previous one.
- [ ] Re-running against the same SHA without "Re-review" reuses the existing row.
- [ ] "Re-review" button forces a fresh run against current SHA, creating a new row.
- [ ] History disclosure lists all rows for the PR, newest first.
- [ ] Switching to a historical review in the modal renders that version's findings (read-only, finding state still mutable).
- [ ] PR card always reflects the latest review's verdict.

## Blocked by

- Issue 08 (Findings UI)
