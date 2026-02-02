# 08 — Findings UI

## What to build

Replace the raw-JSON display from slice 07 with a styled findings UI inside the review modal.

Modal layout:

- Header: verdict badge (`approve` / `request_changes` / `comment`), one-line summary, and `jira_alignment.notes` block (only if present).
- Body: findings grouped into severity sections in fixed order: `blocker`, `major`, `minor`, `nit`, `praise`. Each section collapsible, count shown in section header.
- Each finding row: severity dot/badge, `title`, `file:line` (or `file:line-endLine`), `message` rendered as `AttributedString` markdown, optional `suggestion` shown in a code-block style frame.
- Local state per finding (`open` / `resolved` / `dismissed`) toggled via context menu or right-side menu button on the row. State persisted in SwiftData on the `Finding` model.
- A filter bar above the findings: toggles for "Show resolved" and "Show dismissed", both default off (hidden).
- Live "thinking" stream from slice 07 still visible, but moves into a collapsible "Stream log" disclosure at the bottom of the modal once the run completes.

## Acceptance criteria

- [ ] Modal renders header with verdict, summary, Jira-alignment notes (when present).
- [ ] Findings grouped by severity in the fixed order; counts visible in section headers.
- [ ] Finding row shows title, file:line, markdown-rendered message, and suggestion when present.
- [ ] Click/menu changes finding state to `open`/`resolved`/`dismissed`; choice persists across app restart.
- [ ] Resolved/dismissed findings hidden by default; toggle restores them.
- [ ] No state writes to GitHub or Jira — purely local.
- [ ] Stream log disclosure preserves the live deltas from slice 07.

## Blocked by

- Issue 07 (Tracer bullet — end-to-end review)
