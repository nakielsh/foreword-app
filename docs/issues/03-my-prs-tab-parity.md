# 03 — My PRs tab parity

## What to build

Port the My PRs tab from `index.html` to SwiftUI at feature parity.

Behavior:

- Fetch the user's authored open PRs via REST search: `author:@me+is:pr+is:open`.
- For each PR, fetch via GraphQL: requested reviewers, completed reviews per reviewer, unresolved review threads, total comment counts.
- Per-reviewer status badges: approved / changes requested / commented / pending / re-requested.
- Unresolved threads split into "awaiting you" (the latest comment is from someone else, so the ball is in your court) vs "awaiting others" (the latest comment is from you).
- Total comment count rendered per PR.
- Stats bar: with approvals / changes requested / awaiting your reply / drafts / total.

`GitHubClient` extended with: `fetchAuthoredPRs()`, `fetchPRThreads(repo, number)`, `fetchPRRequestedReviewers(repo, number)`. GraphQL helper added if not already present from slice 01.

## Acceptance criteria

- [ ] Tab fetches authored open PRs on refresh click.
- [ ] Per-reviewer badges render correctly for the 5 states.
- [ ] Unresolved thread counts split into "awaiting you" and "awaiting others" matching `index.html` behavior.
- [ ] Comment count visible on each card.
- [ ] Stats bar values match the rendered cards.
- [ ] 401 handled identically to slice 01.
- [ ] Behavior matches current `index.html` My PRs tab.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
