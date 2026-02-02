# 01 — App skeleton + Reviews tab MVP

## What to build

A new SwiftUI macOS app target (`WorkHomepage.app`) with a single main window, a `NavigationSplitView` sidebar containing four tab entries (Reviews, My PRs, Sessions, Deploys), and a working Reviews tab that displays review-requested PRs as title-only cards.

Establishes the foundation every later slice builds on:

- Xcode project structure with folders for `Models/`, `Services/`, `Views/`, `Resources/`.
- MV pattern, no third-party dependencies.
- Min macOS 14, SwiftData enabled.
- App is not sandboxed, not hardened, ad-hoc signed.
- A single global toolbar refresh button refreshes the active tab. Reviews tab is the only one wired up in this slice; others are placeholder views.
- `KeychainStore` wraps Security.framework with `set`/`get`/`delete`.
- On first launch, the app reads the GitHub token via shelling out to `gh auth token` (if present) and stores it in Keychain. If `gh` is not found, a small sheet prompts the user to paste a token.
- A minimal `GitHubClient` wraps `URLSession` and exposes `fetchReviewRequestedPRs()`. 401 → clears the keychain entry and surfaces a re-auth prompt.
- Reviews tab card shows PR title, repo, author, and number. No filters, badges, or sub-sections yet — those land in slice 02.

## Acceptance criteria

- [ ] App launches into a single window with sidebar showing Reviews / My PRs / Sessions / Deploys.
- [ ] Selecting Reviews shows a refresh button and an empty state until clicked.
- [ ] First launch with no token prompts for one and stores it in Keychain.
- [ ] If `gh` is on PATH, the token is auto-fetched and stored without prompting.
- [ ] Clicking refresh fetches review-requested PRs and renders one card per PR (title, repo, author, number).
- [ ] A 401 from GitHub clears the stored token and surfaces a re-auth prompt.
- [ ] My PRs / Sessions / Deploys tabs render placeholder views (no crash, no data).
- [ ] App builds and runs from Xcode with no third-party dependencies.

## Blocked by

None — can start immediately.
