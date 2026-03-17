# 26 — Jira badge

Source: PRD addendum US 78-82.

## What to build

A small clickable pill on every PR card surface that links to the matched Jira ticket. Hidden entirely when no ticket is found or Jira isn't configured.

Modules:

1. **`JiraBadgeView`** (View, `Views/JiraBadgeView.swift`):
   - Input: `branchName: String`.
   - Reads `JiraConfig` (existing service) for `baseURL`. Reads `TicketKeyExtractor.extract(branchName:)` for the key.
   - Renders nothing (`EmptyView`) if either is nil.
   - Otherwise renders a small pill: `[KEY]` text in `Font.body(size: 12, weight: .semibold)`, fern-green background tint (`Color.accentFern.opacity(0.12)`), fern-green text, rounded capsule.
   - `.help(key)` tooltip showing the ticket key.
   - `.onTapGesture { NSWorkspace.shared.open(URL(string: "\(baseURL)/browse/\(key)")!) }`.

2. **Embedding sites** — drop `JiraBadgeView(branchName: pr.branch)` into:
   - Reviews PR card (pending + reviewed-by-me sub-sections)
   - My PRs PR card
   - Review modal header (`ReviewSheet`)

## Acceptance criteria

- [ ] `JiraBadgePresenceTests`: helper logic returns `nil` (no badge) when extract returns nil; returns nil when `baseURL` is nil; returns `(key, url)` tuple when both present.
- [ ] Visual: a PR with branch `feature/JWT-123` shows `[JWT-123]` pill on its Reviews card, MyPRs card, and Review modal header.
- [ ] PR with branch `main` (no key) shows no pill on any card.
- [ ] When Jira is unconfigured (no `baseURL` in Settings), no pill shows on any PR.
- [ ] Clicking the pill opens `<baseURL>/browse/<KEY>` in the default browser.
- [ ] Hover tooltip shows the ticket key.
- [ ] Pill is styled per Botanical Garden theme (fern green) and adapts to dark mode.
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 19 (theme tokens used for pill colors)
