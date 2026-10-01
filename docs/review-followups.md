# macOS App Review — Remaining Follow-ups

Dump of findings surfaced by the multi-agent deep-dive review (memory/lifecycle, concurrency, security, networking, tests, SwiftUI) that were **not** addressed in the initial fix pass. Top fixes already shipped — see commit history. This file tracks the leftovers ordered by ROI.

## High-ROI follow-ups

### Networking layer

- **Consolidate the four `GitHubClient*.swift` files into one HTTP helper.** `performRequest` + `checkResponse` + auth headers + decoder config are duplicated four times. Drift already happened: `dateDecodingStrategy = .iso8601` is set in `+Reviews` and one `+MyPRs` path, but not in the others. Single helper unblocks every other transport fix.
- **ETag / `If-None-Match` + `URLCache`.** Most GitHub endpoints return ETag; with ETag respected, polling unchanged PRs returns 304 with no rate-limit cost. Multi-day session currently re-downloads tens of MB of identical JSON per hour.
- **Rate-limit awareness.** Parse `X-RateLimit-Remaining` / `X-RateLimit-Reset`; introduce `GitHubError.rateLimited(resetAt: Date)`; have schedulers honour the reset before re-firing. Distinguish primary vs secondary (`Retry-After`) limits.
- **Retries with backoff** for transient 5xx + `URLError.networkConnectionLost` / `.timedOut` / `.notConnectedToInternet`. 2 retries, `0.5s, 2s, 5s`. Don't retry 4xx other than 429.
- **GraphQL 200-with-errors handling** (`+MyPRs.swift:198-203`). Currently throws on any error in `errors[]`, discarding usable `data`. Distinguish "data nil → throw" vs "errors non-empty but data present → log, return data".
- **Decode error context.** `String(describing: DecodingError)` drops `codingPath`. Pretty-print full path + 1KB body snippet so production decode failures are debuggable.
- **Pagination.** `per_page=50` for search caps results; `Link: rel="next"` is never followed. Either bump to `per_page=100` and accept the cap, or add a generic `paginate(urlString:)` helper with a 5-page ceiling.
- **GitHubError.decoding wraps permission errors as decode errors.** `+MyPRs.swift:201-203` throws `decoding("Missing pullRequest…")` when `data.repository = null` — actually a forbidden/notFound. Add typed cases.
- **Per-PR fetch failure silently zeroes the record** (`+Reviews.swift:88-94, 130-139`). `catch { reviews = [] }` makes "fetch failed" indistinguishable from "no reviews". Surface a per-card error indicator.
- **Jira fallback: serve-stale-on-malformed-JSON masks upstream incidents** (`JiraClient.fetchUpdated`, lines 171-209). Distinguish transport vs decode errors; only serve stale on transport.
- **`JiraClient.decodeTicket` empty-string defaults are too forgiving.** Throw if `key` decodes empty; rest can stay defaulted.
- **ADF flatten depth guard** (`JiraClient.swift:407-465`). Add max-depth 64 to prevent stack-blow on pathological inputs.

### Concurrency

- **`@unchecked Sendable` `ProcessBox` was tightened with a lock in this pass**, but `JiraClient.Cache` (line 487) is still `@unchecked Sendable` with `ModelContext` capture. Mark `Cache` `@MainActor`-isolated; remove `@unchecked Sendable`.
- **`CancellationFlag` race** (`ReviewOrchestrator.swift:512-515`). Read from non-isolated stream consumer, written on `@MainActor` — no memory barrier guarantees visibility. Either mark the class `@MainActor` (already the access pattern in practice) or use `OSAllocatedUnfairLock<Bool>`.
- **`WorktreeManager.defaultIsBusy` testable overload** (`:744`) is not `@MainActor`. `MainActor.assumeIsolated` traps fatally if a non-main caller ever uses the seam. Either annotate or take an `async` `isBusy`.
- **`LocalRepoIndex.localPathOrScan` non-transactional `UserDefaults` read-modify-write.** Two concurrent rescans can lose mappings. Serialise scans through an actor.
- **Bound `withTaskGroup` fan-out to 8 concurrent** in `Views/ReviewsTab.swift:674-712, 714-753` and `Views/MyPRsTab.swift:149-183`. 50-PR refresh fans out 100+ requests at once.
- **Settings UI blocks main on subprocess validation** (`SettingsView.swift:110`, `FirstRunWizard.swift:225`). Move `BinaryResolver.validate()` to async/background.
- **`SessionsReader.currentSessions()` runs synchronously on main** in `SessionsTab.swift:98-104`. Wrap in `Task.detached`.
- **`ClosedPRDetector.cleanupClosedPRs` blocks main** by calling `WorktreeManager.evict` synchronously, which spawns `git`. Make detector async.
- **Enable `SWIFT_STRICT_CONCURRENCY=complete`** as a follow-up sweep — surfaces most of the above mechanically.

### Security

- **App Sandbox decision.** `ENABLE_APP_SANDBOX = NO`, no entitlements file. Either document the trust model or enable sandbox with file exceptions for `~/.foreword` + configured local-repo roots.
- **Tighten `ClaudeRunner --allowed-tools`** to read-only by default; explicitly deny `Bash`, `Write`, `Edit`. Wrap user-supplied prompt fields (PR title, Jira summary/description, branch name) in untrusted-content fences.
- **Validate `repo` shape (`^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$`)** at the orchestrator boundary before any worktree/clone op (`WorktreeManager.cloneURL`, `worktreeURL`).
- **Validate git refs.** `branch` is concatenated into `"origin/" + branch` without checks for control chars, leading `-`, `..`. `worktreeURL` keys on `prNumber: Int` so path traversal is dodged today, but defence-in-depth is cheap.
- **Switch to `Logger` with `.private`** for any field that touches API payloads (`PreReviewSummaryRunner`, `JiraClient`). Add a regression test asserting no `Authorization` / token-like substring appears in logs.
- **First-run token bootstrap consent.** `ForewordApp.swift:107-119` silently runs `gh auth token` and clones the result into the app's keychain. Show this step in `FirstRunWizard` before exfiltrating.
- **`KeychainStore`: set `kSecUseDataProtectionKeychain: true`** for stronger app-identity isolation. Consider `SecAccessControlCreateWithFlags(.userPresence)` for the GitHub token if UX permits.
- **Allow-list env var prefixes** forwarded to spawned children in `ShellEnvironment` / `IntelliJLauncher` (currently wholesale-imports `.zshrc` env, including `ANTHROPIC_API_KEY`, AWS creds, etc.). _Done:_ fixed allow-list (`JAVA_*`, `GRADLE_*`, `MAVEN_*`, locale, SSH agent) plus user-configured extras in Settings → Behavior.
- **`LocalRepoIndex.scan` containment check.** After parsing a GitHub repo from a remote URL, sanity-check that the resolved dir lives under one of the configured roots — closes the "malicious `~/src` subdir spoofs `<owner>/<repo>` mapping" amplification.

### SwiftUI / view layer

- **Cache SwiftData stores in `@State`** instead of re-allocating per `body` invocation. Hot spots: `ReviewsTab.swift:212, 257, 544, 768-769`; `ReviewSheet.swift:694, 780`. Each `ReviewStore(context: modelContext)` is allocated per-render, per-PR-card; 30-PR list × frequent re-renders = 30+ SwiftData fetches per second under streaming.
- **Don't hold `Review` SwiftData refs across long-lived `@State`** (`ReviewSheet.swift:60` `@State var historicalReview: Review? = nil`). Row deletion turns the reference into a tombstone; access crashes. Store `PersistentIdentifier`, re-fetch.
- **Throttle `partialStream` animation in `ReviewSheet.swift:927-944`.** Per-token `withAnimation` + `proxy.scrollTo` jitters selection. Debounce (`.onChange` with timer) or sample.
- **`SettingsView.reviewPromptText` writes UserDefaults on every keystroke** (`:400-402`). Debounce or save on commit.
- **De-duplicate the two `.sheet(isPresented: $showReviewSheet)` definitions** in `SidebarView.swift:84-86` and `ReviewsTab.swift:126-131`. Two competing `@State` booleans for the same logical sheet drop dismiss events.
- **Cache `FindingsGrouper.group(visible)`** in `ReviewSheet.swift:579, 691` (recomputed per render).
- **Cache `jiraAlignmentNotes(for review:)` JSON decode** (`ReviewSheet.swift:441-449`) in `@State`; today decoded 10×/sec under streaming.
- **`SettingsView.swift:60-65` `@State` snapshots `LocalRepoIndex.roots`** at view-init; misses the background rescan. Load in `.task` instead.
- **`ForEach(Array(localRepoRoots.enumerated()), id: \.offset)`** in `SettingsView.swift:470` — id by `\.offset` breaks identity on reorder. Id by `root.path`.
- **`@State` for singleton `@Observable` references** (`ReviewsTab.swift:71`, `SidebarView.swift:37`, `MenuBarContent.swift:35`) is an antipattern. Use `let` + `@Bindable` only at leaves needing a binding.
- **Mixed `@Observable` (`ReviewOrchestrator`) and `ObservableObject` (`PreReviewSummaryOrchestrator`)** — pick one. The `let _ = orchestrator.states` dependency hack at `ReviewsTab.swift:1476` shows the migration is incomplete.

### Test quality

- **Critical missing tests:**
  - `ClaudeRunner` Task-cancellation propagation: cancel the consuming Task mid-stream, assert child PID reaped and stream finishes.
  - `ClaudeRunner` invalid-binary / permission-denied → `.error` (not hang/crash).
  - `PreReviewSummaryRunner` real-process path (today only decoder is tested).
  - GitHub 403 rate-limit shape: assert error carries reset time.
  - GitHub timeout / connection-drop typed error.
  - GitHub malformed JSON on 200 → typed decoding error.
  - `KeychainStore` access-denied path (set returns false, get returns nil, no crash).
  - SwiftData schema migration path (no test exists; a model-shape change today silently wipes user data).
  - `ReviewOrchestrator` parallel `start()` invariant: `running.count <= cap`.
  - `WorktreeManager` repeat-`prepare` while another `prepare` is mid-flight on same `(repo, prNumber)`.
  - UI smoke test with assertions: tab bar exists with the 4 expected tabs; Reviews list navigable; token prompt appears with empty keychain.

- **Tests to delete or replace:**
  - `ForewordTests.swift` template stub.
  - `ForewordUITests.testExample` (`app.launch()` with no assertions).
  - `OrchestratorJiraInjectionTests.testRenderJiraBlockExactFormat` + `OrchestratorPromptParentTests.testRenderJiraBlockExactFormatWithParent` — exact-whitespace pin; brittle. Replace with structural assertions.
  - `OrchestratorJiraInjectionTests.testLegacyBuildPromptIsEquivalentToNoJira` — asserts two implementations equal each other; passes if both regress identically.
  - `AppearanceTests.testIdentifiable` + `testRawValueRoundTrip` — round-trip a String enum through itself; tests the compiler.
  - `ReviewPromptStoreTests.testKnownVariableKeysContainsExpectedFour` — re-asserts a constant.
  - `MonogramRendererTests.testNonASCIILoginUsesFirstScalarUppercased` / `testNumericLoginUsesFirstCharacter` — only assert "non-nil and deterministic", not the promised behaviour. Two of these are also currently failing — investigate before deletion.
  - `MenuBarCountsTests.testRefreshReviewsRequestedNotificationNameIsStable` — re-asserts a string constant.
  - `ForewordUITestsLaunchTests.testLaunch` — screenshot without assertion.
  - `AvatarLoaderTests` — tests an `AvatarLoaderSUT` reimplementation, not the real loader. Inject the session into `AvatarLoader.shared` and test the real type.

- **Cross-cutting:**
  - Five duplicated `URLProtocol` stub classes; only one supports transport-failure injection. Unify.
  - `AppSettings.concurrencyCap` mutation in `ReviewOrchestratorConcurrencyTests` touches `.standard`. Add a DI seam (`ReviewOrchestrator(pipeline:concurrencyCap:)`) so tests don't mutate shared state.
  - Several test files re-implement an "AssertJ-style" fluent shim. Consolidate into one `Tests/Helpers/Assertions.swift` to prevent drift.

## Lower priority

- **`BinaryResolver` `kSecCodeSign` validity check** on resolved binaries — punt. Homebrew/PATH trust assumption is now documented in README.

### Done in this pass

- Per-line buffer cap policy comment added in `WorktreeManager.runProcessSync` cross-referencing `ClaudeRunner.maxLineBufferBytes`.
- `AvatarLoader` now appends `?s=96` (merging with existing query) before fetch and cache key.
- `JiraConnectionTester` 401/non-2xx now includes a whitespace-collapsed body snippet (≤200 chars).
- README documents the Homebrew/`/usr/local/bin` trust assumption shared by `BinaryResolver` and `IntelliJLauncher`.
- `IdeaProjectSync` `gradle.xml` / `misc.xml` rewrite ported from regex/string-replace to `XMLDocument` (public API unchanged).
