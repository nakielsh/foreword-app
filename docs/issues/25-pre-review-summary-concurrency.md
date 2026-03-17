# 25 — Pre-Review Summary concurrency pool + retry

Source: PRD addendum US 74, 77.

## What to build

Replace slice 24's single-shot summary execution with a proper orchestrator that has its own concurrency pool, separate from the Review pool. Add retry on failure.

Modules:

1. **`PreReviewSummaryOrchestrator`** (deep, `Services/PreReviewSummaryOrchestrator.swift`, `@MainActor`):
   - State machine per `(prKey, headSha)`: `idle → running → (cached | failed)`.
   - Public surface:
     - `func start(repo: String, prNumber: Int, prKey: String, headSha: String) -> SummaryRunID`
     - `func cancel(_ id: SummaryRunID)`
     - `func state(_ id: SummaryRunID) -> SummaryRunState`
     - `func events(_ id: SummaryRunID) -> AsyncStream<SummaryEvent>`
   - On `start`: cache hit short-circuits, returns synthetic `.cached` event stream that emits the stored summary.
   - Otherwise: enqueue. If active runs < `AppSettings.summaryConcurrencyCap`, dequeue and run via `PreReviewSummaryRunner`. Else surface `Queued (N ahead)` state.
   - Persists via `PreReviewSummaryStore` on `.result`.

2. **`AppSettings`** — add `summaryConcurrencyCap: Int` (default 5, range 1-10). `SettingsView` "Review Prompt" or new "Pre-Review Summary" section gets a Stepper.

3. **Reviews PR card UI** — wired through orchestrator:
   - Replace the direct `PreReviewSummaryRunner` call from slice 24 with `orchestrator.start(...)`.
   - Render `Queued (N ahead)` state when relevant.
   - **Retry button** appears on `.failed` state. Click → `start(...)` again; orchestrator clears prior failure and re-runs.

## Acceptance criteria

- [ ] `PreReviewSummaryOrchestratorTests`: concurrency cap enforces queue ordering (start N+1 with cap N → last one queued); cancel of queued never spawns; cancel of running terminates cleanly; cache hit short-circuits without spawning; failure → retry → success path works.
- [ ] Settings has a "Pre-Review Summary concurrency" stepper bound to `summaryConcurrencyCap`, range 1-10.
- [ ] Reviews PR card shows `Queued (N ahead)` when over cap.
- [ ] Failed summary card has visible "Retry" button; clicking retries.
- [ ] Summary pool is independent of Review pool (running 3 reviews + 5 summaries works simultaneously).
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 24
