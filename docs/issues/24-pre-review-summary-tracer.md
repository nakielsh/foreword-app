# 24 — Pre-Review Summary tracer

Source: PRD addendum US 70-73, 75, 76, 77 (without retry), ADR-0002, CONTEXT.md "Pre-Review Summary".

## What to build

End-to-end Pre-Review Summary on the Reviews tab. Single PR at a time (no concurrency pool yet — that lands in slice 25). No retry button (lands in 25). No worktree (per ADR-0002).

Modules:

1. **SwiftData model** `PreReviewSummary(prKey: String, headSha: String, what: String, why: String, risk: String, generatedAt: Date)` — composite unique on `(prKey, headSha)`.

2. **`PreReviewSummaryStore`** (deep, `Services/PreReviewSummaryStore.swift`):
   - `func existing(prKey: String, headSha: String) -> PreReviewSummary?`
   - `func save(_ summary: PreReviewSummary)`
   - `func dropForPR(_ prKey: String)` — drops every cached summary for that PR regardless of `headSha`. Hooked into the existing PR-close cleanup path that `ReviewStore.dropForPR` uses.

3. **`PreReviewSummaryRunner`** (deep, `Services/PreReviewSummaryRunner.swift`):
   - `func summarize(repo: String, prNumber: Int, headSha: String, timeout: Duration = .seconds(60)) -> AsyncStream<SummaryEvent>`.
   - Spawns `claude -p <prompt> --output-format stream-json --include-partial-messages --json-schema <schema> --allowedTools "Bash(gh:*)"`. No `cwd` set (runs anywhere).
   - JSON schema: `{"what": "string", "why": "string", "risk": "string"}`.
   - Prompt: directs Claude to use `gh pr view <prNumber> --repo <repo>` and `gh pr diff <prNumber> --repo <repo>` to fetch the PR and diff, then return one short sentence each for `what` (the change), `why` (the motivation, inferred from PR body / Jira if linked), and `risk` (regressions, footguns, areas to scrutinize).
   - Streams `SummaryEvent.delta(field: SummaryField, text: String)`, `.result(PreReviewSummary)`, `.error(message: String)`. Hard-kills the process at `timeout`.

4. **Reviews PR card** — render logic:
   - If a cached `PreReviewSummary` exists for `(prKey, headSha)`, render the 3-bullet block inline under the PR title (always visible).
   - Otherwise, show a "Summarize" button.
   - On click: button → spinner + streaming partials. On `.result`: persist via Store, replace UI with cached block. On `.error`: show error text inline (no retry button — that's slice 25).

5. **Drop-on-PR-close** — extend the existing closed-PR cleanup hook (currently calls `ReviewStore.dropForPR` and `WorktreeManager.evict`) to also call `PreReviewSummaryStore.dropForPR`.

## Acceptance criteria

- [ ] `PreReviewSummaryRunnerTests`: streamed deltas arrive in order; final structured payload decodes; non-zero exit yields `.error`; 60s timeout kills process.
- [ ] `PreReviewSummaryStoreTests`: save+existing round-trips byte-equal; `dropForPR` removes all summaries for that key regardless of `headSha`; new `headSha` does not collide with old.
- [ ] Reviews PR card shows "Summarize" button when no cache; clicking runs Claude; final result renders as 3 bullets.
- [ ] Re-clicking on cached card: instant render, no spawn.
- [ ] Closing a PR (existing test fixture path) drops its cached summary.
- [ ] No worktree is created or touched by the summary path.
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 19 (theme used for button + bullet styling)
