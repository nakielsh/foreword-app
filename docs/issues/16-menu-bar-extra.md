# 16 — MenuBarExtra (counts, click focuses)

## What to build

Add a `MenuBarExtra` companion to the main app for at-a-glance status without needing the main window open.

Display:

- Icon (a small custom SF Symbol or simple glyph).
- Adjacent text: counts in the format `R<awaiting> · ⚙<in-flight>` where:
  - `R<awaiting>` = number of review-requested PRs not yet reviewed by the user.
  - `⚙<in-flight>` = number of running + queued reviews.
- Click opens a small menu listing:
  - "Show window" — focuses the main window (or recreates it if closed).
  - "Refresh Reviews" — triggers the Reviews-tab refresh remotely.
  - "Quit".

Counts update live as the orchestrator state changes and as the Reviews tab refreshes. No polling; everything is event-driven from existing app state.

## Acceptance criteria

- [ ] MenuBarExtra appears at app launch.
- [ ] Counts reflect current state (awaiting reviews + in-flight reviews).
- [ ] Click opens the menu; "Show window" brings the main window forward.
- [ ] "Refresh Reviews" triggers the same path as the toolbar refresh button.
- [ ] Quitting from the menu cleanly shuts down running reviews (cancels them).
- [ ] Counts update when the Reviews tab refreshes or when reviews start/finish/cancel.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
- Issue 07 (Tracer bullet — end-to-end review)
