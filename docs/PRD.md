# PRD — Native macOS Dashboard with Claude Code Reviews

## Problem Statement

Today the dashboard is a `file://` HTML page (`index.html`) backed by a Python helper script and a launchd agent. The browser is a dead end for the next round of features I want:

- I can see PRs assigned to me for review, but I cannot trigger any work from there. Reviewing a PR still means switching to the terminal, checking out the branch (which clobbers my current working tree), opening the diff, possibly opening Jira to remember what the ticket actually wanted, and then doing the review by hand.
- I want to click a PR in the Reviews tab and have an automated Claude Code review run against the right branch, with the right Jira context, in an isolated worktree, then surface the findings in the dashboard with one-click jumps into IntelliJ at the relevant file and line.
- A `file://` page cannot spawn `claude`, run `git`, or launch `idea`. Bolting a local HTTP server in front of the existing HTML works, but I would rather rewrite as a single native macOS app — better lifecycle, native process spawning, Keychain instead of `localStorage`, a proper sidebar/menu bar, and one codebase to maintain instead of HTML + Python + launchd plist.

I am the only user. I want to ship a focused tool that fits my workflow, not a product.

## Solution

A native SwiftUI macOS app (`WorkHomepage.app`) that replaces `index.html`, `refresh-sessions.py`, `refresh-sessions.sh`, the launchd plist template, and `claude-sessions.js`. The app keeps the four existing tabs (**Reviews**, **My PRs**, **Claude Code**, **Deployments**) at parity with the current HTML, and adds a Claude-powered code-review workflow attached to the Reviews tab.

From my perspective:

1. I open the app. It refreshes my review-requested PRs (manually, on a button click — same as today).
2. On any PR card, I click **Review**. A modal sheet opens. While I watch, the app:
   - Auto-clones the repo as a bare clone the first time (`~/.work-homepage/repos/<org>/<repo>.git`), then creates a worktree at `~/.work-homepage/worktrees/<org>/<repo>/<pr#>/` against the PR head.
   - Extracts the Jira key from the branch name (`feature/JWT-123` → `JWT-123`), fetches the ticket, and if it's a thin subtask, also fetches the parent.
   - Spawns `claude -p ...` in the worktree with a strict allowed-tools list, streaming events back to the modal so I see live progress.
   - Receives a structured JSON result with verdict, summary, Jira-alignment notes, and a list of findings (severity, file, line, title, message, optional suggestion).
3. The modal renders findings grouped by severity. Clicking a finding launches IntelliJ at the worktree, jumping to the right file and line.
4. I can mark findings `resolved` or `dismissed` locally — nothing is ever written back to GitHub or Jira.
5. When the PR closes/merges, the worktree and reviews for that PR are dropped.

The app is for me only. Ad-hoc signed, no notarization, no App Store, no App Sandbox.

## User Stories

### Reviews tab — base behavior

1. As a developer, I want to see all PRs where I am a requested reviewer, so that I know what is waiting on me.
2. As a developer, I want to filter out PRs that already have N+ approvals, so that I can focus on PRs that still need attention.
3. As a developer, I want to see PRs I have already reviewed, grouped by my last review state (changes requested / commented / approved), so that I know what to follow up on.
4. As a developer, I want a "new commits since your review" badge on already-reviewed PRs, so that I notice when I need to look again.
5. As a developer, I want to manually refresh the Reviews tab via a button, so that I control when network calls happen.

### Reviews tab — Claude review workflow

6. As a developer, I want to click **Review** on a PR card, so that an automated review runs without me touching the terminal.
7. As a developer, I want each review to run in an isolated git worktree, so that my main checkout is never disturbed.
8. As a developer, I want repos to auto-clone the first time I review one of their PRs, so that I do not have to set anything up per repo.
9. As a developer, I want clone progress surfaced in the UI on first review, so that I know the app is working and not hung.
10. As a developer, I want subsequent reviews of the same PR to reuse the bare clone, so that they start fast.
11. As a developer, I want re-reviews to fetch the latest head and `git reset --hard`, so that I always review the current state.
12. As a developer, I want all reviews to be manually triggered, so that the app never spends my Claude credits without me asking.
13. As a developer, I want to run up to 3 reviews concurrently (configurable 1-10), so that I can review multiple PRs in parallel without melting my machine.
14. As a developer, I want a 4th queued review to show "Queued (N ahead)", so that I know it will run.
15. As a developer, I want to cancel a queued or running review, so that I can stop wasted work.
16. As a developer, I want a hard 10-minute timeout per review run, so that a stuck `claude` process cannot eat my session forever.
17. As a developer, I want to see live streaming output from Claude while the review runs, so that I can tell if it is making progress.
18. As a developer, I want each new commit on a PR to produce a new versioned review row keyed on `headSha`, so that I never lose history when re-reviewing.
19. As a developer, I want all reviews and the worktree dropped when a PR is closed/merged, so that I do not accumulate stale state.
20. As a developer, I want a manual "Evict worktree" button per PR, so that I can free up disk if I want to.

### Jira integration

21. As a developer, I want the app to extract the Jira ticket from the branch name (`feature/JWT-123`, `bugfix/JWT-456`, etc.), so that I do not have to paste anything.
22. As a developer, I want the matched Jira ticket title and description sent to Claude as part of the review prompt, so that Claude knows what the ticket actually wants.
23. As a developer, I want subtasks with thin descriptions to also fetch the parent ticket's description, so that Claude has the real context (we frequently put the meat in the parent and use subtasks as breakdown).
24. As a developer, I want Jira tickets cached locally and refreshed only when the `updated` timestamp changes, so that reviews do not slow down on Jira's API every time.
25. As a developer, I want reviews to run even when no Jira key is detected, so that I can still review repo-local PRs with no ticket.
26. As a developer, I want the modal to show which Jira ticket was used (with parent if applicable), so that I can verify the right context was passed.

### Findings UI

27. As a developer, I want findings grouped by severity (blocker / major / minor / nit / praise), so that I can triage at a glance.
28. As a developer, I want the modal to show the verdict, summary, and Jira-alignment notes at the top, so that I can take in the high-level call before drilling in.
29. As a developer, I want each finding to show file path, line range, title, message, and optional suggestion, so that I can act on it.
30. As a developer, I want to click a finding and have IntelliJ open the worktree project and jump to that file:line, so that I can investigate without copy-pasting paths.
31. As a developer, I want to mark a finding `resolved` or `dismissed` locally, so that I can clean up the list as I work through it.
32. As a developer, I want resolved/dismissed findings hidden by default and toggleable, so that the list stays focused.
33. As a developer, I want findings state stored only locally and never written to GitHub or Jira, so that I am not posting noisy automated comments to my coworkers.
34. As a developer, I want to see prior versions of a review (one per `headSha`), so that I can compare what changed.

### Other tabs (parity port)

35. As a developer, I want the **My PRs** tab to show my open authored PRs with per-reviewer status badges, unresolved thread counts split between "awaiting you" and "awaiting others", and total comment counts — same as today.
36. As a developer, I want the **Claude Code** tab to show currently-running Claude Code sessions, read on-demand from `~/.claude/sessions/*.json` and `~/.claude/history.jsonl`, with PID liveness validated.
37. As a developer, I want the **Deployments** tab to show the latest deployment per service per environment for the `Ala-com` org, parsed from the configured workflow's run names.
38. As a developer, I want all four tabs refreshable via a single toolbar refresh button, so that I keep the manual-refresh model from today.

### Auth, secrets, settings

39. As a developer, I want my GitHub token in the macOS Keychain, bootstrapped from `gh auth token` on first launch, so that it is not sitting in plaintext.
40. As a developer, I want my Jira email and API token in the Keychain too, configured via a Settings UI, so that I do not have to re-enter them.
41. As a developer, I want the app to probe and persist absolute paths for `claude`, `gh`, `git`, and `idea` on first launch, so that the GUI app's missing shell `PATH` does not break process spawning.
42. As a developer, I want a Settings UI that shows the resolved binary paths with green/red status dots and editable overrides, so that I can fix detection issues quickly.
43. As a developer, I want a first-run wizard that walks me through GitHub token, Jira config, binary paths, project key prefixes, and concurrency cap, so that I can get to working state in one pass.

### App-shell behavior

44. As a developer, I want a single main window with sidebar tabs (Reviews / My PRs / Sessions / Deploys), so that the app feels native.
45. As a developer, I want a `MenuBarExtra` showing at-a-glance counts (awaiting reviews, in-flight reviews), so that I can monitor without keeping the window open.
46. As a developer, I want failed/timed-out reviews to keep their partial stream and error message, so that I can debug what went wrong.
47. As a developer, I want a Settings view showing total disk usage of bare clones + worktrees, with per-repo "evict cache" buttons, so that I can manage disk on my own terms.

## Implementation Decisions

### Architecture

- **Native SwiftUI macOS app, full rewrite.** Replaces `index.html`, `refresh-sessions.py`, `refresh-sessions.sh`, `refresh-claude-sessions.plist.template`, and `claude-sessions.js`. Those files are deleted post-port.
- **Single Xcode project**, single app target. MV pattern (no MVVM ceremony for a solo app).
- **Min macOS 14+** (Sonoma) for SwiftData. Bumping to 15 acceptable.
- **Zero third-party dependencies**: `URLSession` for HTTP/GraphQL, `Security.framework` for Keychain, `AttributedString` markdown for rendering, `Codable` for JSON, native SwiftData for persistence.
- **No App Sandbox, no Hardened Runtime**, ad-hoc signed. Self-use only — no MAS, no notarization. App spawns arbitrary binaries via `Process`, which sandboxing forbids.

### Module surface

- **WorktreeManager** — deep module. Owns bare clones at `~/.work-homepage/repos/<org>/<repo>.git` and worktrees at `~/.work-homepage/worktrees/<org>/<repo>/<pr#>/`. Public surface: `prepare(repo, branch, sha) -> WorktreePath`, `refresh(repo, prNumber, sha)`, `evict(repo, prNumber)`, `evictAllForRepo(repo)`, `diskUsage() -> Bytes`. Encapsulates first-time clone (bare), subsequent fetch, worktree add/reset, partial-clone cleanup on failure, SSH-vs-HTTPS choice (SSH if `~/.ssh/id_*` exists, else HTTPS via `gh auth git-credential`).

- **ClaudeRunner** — deep module. Public surface: `run(prompt: String, schema: JSONSchema, cwd: URL, allowedTools: [String], timeout: Duration) -> AsyncStream<ClaudeEvent>`. Spawns `claude -p ... --output-format stream-json --include-partial-messages --json-schema <schema>` with `--allowedTools "Read,Grep,Glob,Bash(gh:*),Bash(git:*)"`. Reads stdout/stderr line-by-line, decodes each line as a `ClaudeEvent` enum (text delta, tool call, final result with structured payload, error). Enforces 10-minute hard kill. Surfaces `Process` exit code and stderr on failure.

- **GitHubClient** — deep module. Wraps REST and GraphQL endpoints already used in the HTML version. Public surface: `fetchReviewRequestedPRs()`, `fetchReviewedByMePRs()`, `fetchAuthoredPRs()`, `fetchPRThreads(repo, number)`, `fetchWorkflowRuns(repo, workflow, perPage, pages)`, `fetchPRDetails(repo, number)`. Token sourced from `KeychainStore`. 401 → clear token, prompt re-auth.

- **JiraClient** — deep module. Public surface: `fetchTicket(key) -> Ticket?` where `Ticket` has `summary, description (plaintext), status, issuetype, priority, parent: Ticket?`. If the fetched ticket has `fields.parent` and its own description is missing or shorter than ~100 chars, recursively fetches the parent (one level only) and attaches it. Caches by `(key, updated)` in SwiftData. Auth via Keychain (Atlassian Cloud, email + API token, basic auth header).

- **TicketKeyExtractor** — deep, pure. Public surface: `extract(branchName: String) -> String?`. Regex: `(feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)`, returns capture group 2. Returns nil if no match.

- **SessionsReader** — deep module. Public surface: `currentSessions() -> [Session]`. Reads `~/.claude/sessions/*.json`, validates each PID via `Darwin.kill(pid, 0)`, drops dead. Tails `~/.claude/history.jsonl`, groups last entry per session cwd, truncates to 200 chars. Sorts newest-first. On-demand only (no FSEvents, no polling) — runs when the user clicks refresh on the Sessions tab.

- **DeploymentsParser** — deep, pure. Public surface: `parse(runName: String) -> Deployment?` returning `(env, version)`. Same regex as current HTML implementation. Pure, no I/O.

- **ReviewStore** — deep module over SwiftData. Models: `Review(id, prKey, headSha, state, startedAt, finishedAt, summary, verdict, jiraKey, jiraSnapshot, errorMessage, partialStream)`, `Finding(id, reviewId, severity, file, line, endLine?, title, message, suggestion?, state)`, `JiraTicket(key, summary, description, parentKey?, updated)`, `WorktreeRecord(repo, prNumber, path, headSha, createdAt)`. Public surface: `addReview(prKey, headSha) -> Review`, `versions(prKey) -> [Review]`, `latestForPR(prKey) -> Review?`, `dropForPR(prKey)`, `markFindingState(id, state)`.

- **BinaryResolver** — deep module. Public surface: `resolve(.claude | .gh | .git | .idea) -> URL?`, `validate(allTools) -> [Tool: Status]`, `setOverride(.claude, URL)`. Probes `/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local`, `/Applications/IntelliJ IDEA.app/Contents/MacOS`, etc. Persists resolved paths in `UserDefaults`.

- **ReviewOrchestrator** — deep module, composition root. Public surface: `start(pr: PRRef) -> ReviewID`, `cancel(ReviewID)`, `state(ReviewID) -> ReviewState`, `events(ReviewID) -> AsyncStream<ReviewEvent>`. Owns the state machine `queued → running → (completed | cancelled | failed | timeout)`. Enforces concurrency cap (default 3, configurable). Coordinates `WorktreeManager`, `JiraClient`, `ClaudeRunner`, `ReviewStore`. On completion, parses the final structured payload from `ClaudeEvent.result` and persists `Findings`.

- **KeychainStore** — shallow wrapper around `Security.framework`. Public surface: `set(key, value)`, `get(key) -> String?`, `delete(key)`.

- **IntelliJLauncher** — shallow. Public surface: `open(worktree: URL, file: String, line: Int)`. Spawns `idea --line N <worktree>/<file>`. Falls back to `open -a "IntelliJ IDEA"` if `idea` CLI absent (surfaces error, does not silent-fail).

### Claude prompt + tool perms

- `claude -p <prompt> --output-format stream-json --include-partial-messages --json-schema <schema>`.
- `--allowedTools "Read,Grep,Glob,Bash(gh:*),Bash(git:*)"`. No file writes, no broad bash, no network beyond `gh`.
- Prompt structure: PR meta (title, body, author) + Jira block (or `null`) + instruction to use `gh` to fetch the diff and any further context, then return schema-conformant JSON.

### Output schema

```json
{
  "summary": "string",
  "verdict": "approve | request_changes | comment",
  "findings": [
    {
      "severity": "blocker | major | minor | nit | praise",
      "file": "path/relative/to/repo.kt",
      "line": 42,
      "endLine": 45,
      "title": "short headline",
      "message": "1-3 sentences",
      "suggestion": "optional code fix or null"
    }
  ],
  "jira_alignment": {
    "matches_ticket": true,
    "notes": "string"
  }
}
```

### Concurrency + state

- Concurrency cap default 3, configurable 1-10. 4th request goes to queue, surfaces "Queued (N ahead)" badge. Queue drained FIFO.
- Cancellation kills the `Process`, marks review `cancelled`, drops streamed text, keeps no findings. Worktree retained.
- Failure (non-zero exit, decode error) → state `failed`, partial stream + stderr stored.
- 10-minute timeout → state `timeout`, partial stream stored.

### Storage + secrets

- SwiftData store under app's container directory. No iCloud sync.
- Keychain entries: `github.token`, `jira.email`, `jira.token`, `jira.baseURL`.
- No Anthropic API key managed by app — `claude` CLI handles its own auth, app inherits user env on spawn.

### Lifecycle

- First launch → first-run wizard (GH token, Jira config, binary paths, project key prefixes, concurrency cap). Re-openable from Settings.
- App not sandboxed — explicit absolute paths for all binaries. `Process` configured with `executableURL` (never `/bin/zsh -lc`), `currentDirectoryURL` set to worktree, `environment` minimal (`HOME`, `USER`, constructed `PATH`).
- Manual refresh model preserved everywhere. Optional auto-refresh toggle for PR list (default off). Reviews always manual.

### Repo restructure

After ship:
- Add `WorkHomepage.xcodeproj` + `WorkHomepage/` source tree (`Models/`, `Services/`, `Views/`, `Resources/`).
- Delete `index.html`, `claude-sessions.js`, `refresh-sessions.py`, `refresh-sessions.sh`, `refresh-claude-sessions.plist.template`.
- Rewrite `README.md` for Xcode build instructions and first-run wizard.
- Rewrite `CLAUDE.md` for the new structure.

### Phased rollout

1. Skeleton + Reviews tab read-only (parity with current HTML).
2. My PRs + Sessions + Deployments tab ports.
3. Worktree + Claude runner + findings UI + IntelliJ launcher.
4. Jira integration.
5. Polish: menu bar extra, settings disk usage view, finding state filters.

Each phase shippable on its own.

## Testing Decisions

**Test philosophy:** test external behavior of deep modules with realistic inputs. No mocking of internal collaborators we own; use real implementations with fixture inputs (temp dirs, fixture JSON, fake binaries on PATH). Pure modules get pure unit tests. Avoid testing SwiftUI Views.

**Modules with tests:**

- **TicketKeyExtractor** — pure function. Table-driven tests over branch names: `feature/JWT-123` → `JWT-123`, `bugfix/PROJ-1`, `hotfix/AB-9999`, branches without prefix, branches with multiple keys (first wins), main/master/non-conforming names → nil. Easy, high-value.

- **DeploymentsParser** — pure function. Table-driven tests over real workflow run names from current HTML implementation, including `[dev] Deploy v1.21.1-feature-xyz-snapshot`, prod-style names, malformed names, names without env tag.

- **WorktreeManager** — integration tests over a temp `HOME`. Use a local fixture bare repo (`git init --bare` in test setup) instead of network. Cover: first-time clone creates expected dir structure; second clone is a no-op; `prepare` creates worktree at right path; `refresh` advances head and resets dirty state; `evict` removes worktree but keeps bare clone; `evictAllForRepo` removes both; partial-clone failure leaves no orphaned dir.

- **ClaudeRunner** — integration tests with a fake `claude` binary (a small shell script in the test bundle that emits a canned sequence of stream-json lines on stdin trigger). Cover: streamed events arrive in order; final structured payload decodes; non-zero exit surfaces stderr; timeout kills process and yields `timeout` event; cancellation kills process cleanly.

- **ReviewOrchestrator** — state machine + concurrency tests. Substitute `ClaudeRunner` and `WorktreeManager` only at the public-surface level using test doubles that mimic real timing. Cover: state transitions for happy path / cancel / fail / timeout; concurrency cap of N enforces queue ordering; cancel of queued review never spawns; cancel of running review terminates and reaches terminal state; concurrent starts on the same `(prKey, headSha)` deduplicate or version correctly per the chosen rule.

- **JiraClient** — integration tests over `URLProtocol` stubs. Cover: ticket without parent decodes correctly; subtask with thin description triggers parent fetch and attaches it; subtask with rich description does NOT trigger parent fetch; ADF description flattening to plaintext; cache hit when `updated` unchanged; cache invalidation when `updated` changes; auth failure surfaces clearly.

**Modules without tests:**

- **KeychainStore** — thin wrapper over Apple API; tests would mostly verify Apple. Manual smoke check during first-run wizard.
- **IntelliJLauncher** — thin `Process` shellout; tests would mostly verify `Process`. Manual smoke check.
- **GitHubClient** — thin REST mapping. The interesting logic (filtering, derived state like "approvals count", "new commits since review") lives in view-models or selectors which can be tested separately if they grow non-trivial.
- **SessionsReader** — debatable. Add tests later if logic accretes (right now: list dir, parse JSON, ping PID, tail jsonl — mostly Foundation calls).
- **BinaryResolver** — manual; depends on real filesystem layout.
- **Views** — SwiftUI; visual verification via Previews and live use.

**Prior art:** none in this repo (current code is browser JS, no test suite). Establish a single `WorkHomepageTests` target with one folder per module.

## Out of Scope

- Posting findings as GitHub PR review comments. Findings are local-only, on purpose.
- Editing files or applying suggested fixes from claude. Worktree is read-only to claude.
- Running tests or builds from claude. Default off; possible later toggle.
- Mac App Store distribution. Self-use only, ad-hoc signed.
- Notarization, hardened runtime, sandboxing.
- iCloud sync of reviews / settings.
- Cross-machine setup / sharing of reviews with teammates.
- Slack/Linear/etc. notifications when a review completes.
- Automatic re-review on push (only manual re-review supported).
- Auto-refresh of the Reviews list (manual only by default; optional toggle for PR list refresh, never for reviews).
- Multi-org Deployments tab generalization (still hardcoded to `Ala-com`, configurable via Settings later).
- Anthropic API key management (delegated entirely to `claude` CLI).
- Linux/Windows support.
- Anything iOS.

## Further Notes

- The current dashboard's Deployments tab pages through up to 200 workflow runs to avoid prod info being buried by frequent dev deploys. Native port preserves this.
- The current Reviews tab has subtle behavior around "PRs you reviewed that are no longer pending review" (Changes Requested / My Comments / Already Approved sub-sections, with new-commits-since-review badges and re-review state). Native port must preserve this — it is one of the main reasons the current dashboard is useful.
- The current `ghFetch` / `ghGraphQL` helpers handle 401 → token clear. Equivalent behavior in `GitHubClient` should clear keychain entry and surface a Settings nudge.
- ADF (Atlassian Document Format) flattening: a small recursive walk that concatenates `text` nodes and emits `\n\n` for paragraph/heading boundaries is sufficient for prompt context. No need for real renderer.
- Settings should expose: GitHub token (re-paste), Jira config (URL/email/token + test connection), binary paths with re-detect, project key prefixes (default permissive `[A-Z]+-\d+`), concurrency cap, retention policy.
- README and CLAUDE.md updates are part of the final phase, after the rewrite is functional.
- No tracker is currently configured for this project (no git remote, no GitHub repo). PRD lives at `docs/PRD.md`. When/if a tracker is set up, this PRD can be reposted with the `ready-for-agent` label per the standard `to-prd` flow.
