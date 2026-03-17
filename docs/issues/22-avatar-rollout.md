# 22 — Avatar rollout (MyPRs reviewers + Review modal)

Source: PRD addendum US 53-56.

## What to build

Extend `ReviewerAvatarView` (from slice 21) to every remaining surface where a person is named.

Surfaces:

1. **MyPRs tab** — each `ReviewerEntry` in a PR card renders inline as `[avatar] @<login> [status pill]`. Author also gets an avatar at the top of the card.
2. **Review modal (`ReviewSheet.swift`)** — author avatar in the header next to PR title.

Plumbing:

1. **`MyPRsModels.ReviewerEntry`** — add `avatarURL: URL?`. Default nil for backwards compat in test fixtures.
2. **`GitHubClient+MyPRs`** — extend the existing GraphQL query so `latestReviews { nodes { author { login avatarUrl } } }` and the parallel `reviewRequests { nodes { requestedReviewer { ... on User { login avatarUrl } } } }`. Plumb `avatarUrl` through `ReviewerEntryBuilder` into the final `ReviewerEntry`.
3. **`MyPRsModels.AuthoredPR.User`** — extend with `avatarURL: URL?` (existing `User` only has `login`). REST search payload returns `user.avatar_url` already; just add the field + `CodingKey`.

## Acceptance criteria

- [ ] My PRs cards show 24px reviewer avatars inline before each login + status pill.
- [ ] My PRs cards show 24px author avatar at the top.
- [ ] Tooltips on My PRs reviewer avatars read `@<login> — Reviewer (<Status>)`.
- [ ] Review modal header shows 24px author avatar next to PR title and meta.
- [ ] GraphQL query updated to include `avatarUrl` on both `latestReviews.author` and `reviewRequests.requestedReviewer`.
- [ ] `GitHubClientMyPRsTests` updated: new GraphQL response fixtures include `avatarUrl`; decoded `ReviewerEntry` carries the URL.
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 21
