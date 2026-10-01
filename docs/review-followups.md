# macOS App Review — Remaining Follow-ups

Leftovers from the multi-agent deep-dive review of the macOS app (memory/lifecycle, concurrency, security, networking, tests, SwiftUI). Most of the original list has shipped (summary at the bottom, details in git history). This file tracks what is still open, ordered by ROI.

## Open

### Networking

- **Per-PR fetch failure silently zeroes the record** (`GitHubClient+Reviews.swift`, both `catch { reviews = [] }` sites, marked `TODO(networking-followup)`). "Fetch failed" is indistinguishable from "no reviews". Surface a per-card error indicator.
- **Nothing branches on `GitHubError.rateLimited(resetAt:isSecondary:)` yet.** `HTTPClient` raises it, but no tab or `MenuBarCounts` handles it specifically. Show the reset time instead of a generic error.

### Concurrency

- **Enable `SWIFT_STRICT_CONCURRENCY=complete`** (not set in the project). Several `@unchecked Sendable` boxes (`ProcessBox`, `CancellationFlag`) are lock-backed and fine today; the sweep would make the compiler check the rest.
- **`ReviewsTab` still calls the synchronous `ClosedPRDetector.cleanupClosedPRs`**, which spawns `git worktree remove` on the main actor. `cleanupClosedPRsAsync(openPRKeys:)` exists; migrate the caller and delete the sync entry point.

### Security

- **`KeychainStore`: data-protection keychain.** `useDataProtectionKeychain` is wired but `false`, because it needs a keychain-access-group entitlement and the app ships without an entitlements file. Flip it when the entitlements file lands (see `docs/release.md`). Consider `SecAccessControlCreateWithFlags(.userPresence)` for the GitHub token if UX permits.
- **Switch to `Logger` with `.private`** for anything that touches API payloads. `JiraClient` still uses `NSLog` with interpolated errors and keys; there are no `privacy: .private` call sites anywhere. Add a regression test asserting no `Authorization` / token-like substring reaches the logs.

### SwiftUI / view layer

- **Mixed `@Observable` (`ReviewOrchestrator`) and `ObservableObject` (`PreReviewSummaryOrchestrator`).** Migrate the summary orchestrator to `@Observable`; that also removes the `let _ = orchestrator.states` dependency hack in `ReviewsTab.swift`.

### Test quality

- **`WorktreeManager` concurrent `prepare` on the same `(repo, prNumber)`** — `WorktreeManagerInFlightDedupTests` documents the desired contract but is parked behind `XCTSkipIf(true, …)` because `prepare` doesn't de-duplicate yet. Implement the dedup, then un-skip.
- **`MonogramRenderer`** — two tests are skipped pending renderer fixes (whitespace/empty logins hash differently; FNV-1a % 360 collides on the fixture set). `testNonASCIILoginUsesFirstScalarUppercased` and `testNumericLoginUsesFirstCharacter` still only assert "non-nil and deterministic", not the glyph they promise.
- **`KeychainStore` access-denied path** (set returns false, get returns nil, no crash) has no test.
- **Three per-file `URLProtocol` stubs remain** (`StubURLProtocol` in `GitHubClientTests`, `JiraCacheStubURLProtocol`, `JiraStubURLProtocol`) next to the shared `Helpers/URLProtocolStub.swift`. Fold them into the shared one.
- **`ReviewOrchestratorConcurrencyTests` mutates `AppSettings.concurrencyCap` on `.standard`.** Add a DI seam (`ReviewOrchestrator(pipeline:concurrencyCap:)`) so tests don't touch shared state.

## Lower priority

- **`BinaryResolver` code-signature check** on resolved binaries — punted. The Homebrew / `/usr/local/bin` trust assumption is documented in README and SECURITY.md, and every tool can be pinned to a fixed path in Settings → Tools.

## Already shipped

For reference, so nobody re-opens these:

- **Networking:** single `HTTPClient` under every `GitHubClient*` file (shared headers and decoder); ETag / `If-None-Match` with a shared `URLCache`; typed `rateLimited` / `forbidden` / `notFound` / `graphqlPartial` errors; retries with 0.5s / 2s / 5s backoff for transient failures; GraphQL 200-with-errors returns partial data; decode errors carry `codingPath` and a body snippet; `per_page=100` plus `Link: rel="next"` pagination with a 5-page ceiling; Jira serves stale cache only on transport errors; `decodeTicket` rejects an empty key; ADF flattening has a depth guard.
- **Concurrency:** `JiraClient.Cache` is `@MainActor`; `CancellationFlag` uses `OSAllocatedUnfairLock`; `WorktreeManager.defaultIsBusy` is `@MainActor`; `LocalRepoIndex` scans serialise on a lock; per-PR enrichment fan-out capped at 8; binary validation, session reading and closed-PR eviction (async variant) run off the main actor.
- **Security:** `claude` runs with an explicit allow-list and deny-list; branch names and Jira text are fenced as untrusted content; repo identifiers and branch names are validated before any git call; the `gh auth token` bootstrap only runs on an explicit click in the first-run wizard; IntelliJ's environment is allow-listed with user-configurable extras; `LocalRepoIndex` checks that mapped clones live under a configured root; the no-sandbox trust model is documented in SECURITY.md.
- **SwiftUI:** `ReviewStore` cached in `@State`; historical reviews held by `PersistentIdentifier`; live stream throttled; review prompt saves debounced; one owner for the review surface (now a separate `Window` scene); findings grouping and Jira-notes decode memoised; Local Repos roots loaded in `.task` and identified by path; singleton `@Observable` references held with `let`.
- **Tests:** template stubs and assertion-free tests removed; brittle exact-whitespace and self-equivalence tests replaced; `AvatarLoaderTests` drive the real loader; one shared AssertJ-style `Helpers/Assertions.swift`; new coverage for `ClaudeRunner` cancellation and bad binaries, the `PreReviewSummaryRunner` process path, GitHub rate-limit / timeout / malformed-JSON errors, the SwiftData on-disk reopen, the orchestrator's parallel-start cap invariant, and a UI smoke test for the three sidebar tabs and the token prompt.
- **Misc:** per-line buffer cap documented in `WorktreeManager.runProcessSync`; `AvatarLoader` requests `?s=96`; `JiraConnectionTester` errors include a body snippet; `IdeaProjectSync` rewrites `gradle.xml` / `misc.xml` via `XMLDocument`.
