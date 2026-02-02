# 02 — Reviews tab full parity

## What to build

Bring the Reviews tab to feature parity with the current `index.html` Reviews tab.

Specifically:

- A filter bar with two controls: "Hide PRs with >= N approvals" dropdown (threshold 1–5, default 2) and "Show my dismissed reviews" toggle.
- A stats bar showing counts: awaiting / with approvals / drafts / dismissed / currently showing.
- The main grid of pending review-requested PRs (already rendered by slice 01) gets richer card content: approval count, draft status, dismissed badge, requested-reviewers list.
- Three additional sub-sections rendered below the main grid, populated from `reviewed-by:@me` PRs that are no longer in the pending set:
  - **Changes Requested** — your last review state was `CHANGES_REQUESTED`.
  - **My Comments** — your last review state was `COMMENTED`.
  - **Already Approved** — your last review state was `APPROVED`.
- Each reviewed PR card shows a "N new commits since your review" badge when commits were pushed after your last review (compare commit SHA timestamps to last review submitted_at), and a re-review state indicator showing your prior review state.
- Filter state and currently selected tab persisted in `UserDefaults`.

## Acceptance criteria

- [ ] Filter bar renders, threshold dropdown defaults to 2, dismissed toggle defaults to off.
- [ ] Stats bar updates live as filters change.
- [ ] Pending grid hides PRs that meet/exceed the approval threshold unless toggle says otherwise.
- [ ] Three sub-sections render PRs from `reviewed-by:@me` grouped by my last review state.
- [ ] "N new commits since your review" badge is correct on PRs with commits after `submitted_at`.
- [ ] Re-review state indicator visible on each reviewed PR.
- [ ] Filter state survives app restart.
- [ ] Behavior matches current `index.html` Reviews tab.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
