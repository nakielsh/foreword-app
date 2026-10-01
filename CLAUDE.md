# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Foreword** is a SwiftUI + SwiftData macOS app (`Foreword/`) for the GitHub pull requests waiting on you: PRs you've been asked to review, PRs you authored, and running Claude Code sessions. On top of that it runs Claude-driven PR reviews in isolated worktrees with Jira context, pre-review summaries, an IntelliJ jump-to-line launcher, and a menu-bar companion. New work targets the app.

The repo also keeps the HTML dashboard the app grew out of (`index.html` + `refresh-sessions.*`, see [Legacy HTML dashboard](#legacy-html-dashboard)). It is maintained only as long as it stays zero-cost; features land in the app, not there.

For domain vocabulary (Review vs. GitHub review, Pre-Review Summary, Worktree, Jira Ticket / Parent, Review Prompt Template), see `CONTEXT.md`. For architecture decisions, see `docs/adr/`. For slice-by-slice implementation history, see `docs/issues/`.

## macOS app

Xcode project at `Foreword/Foreword.xcodeproj`. SwiftUI scenes + SwiftData persistence, zero third-party dependencies. Deployment target macOS 26.4 (Apple Silicon). Not sandboxed, no Hardened Runtime. Uses synchronized folder groups, so files added under `Foreword/Foreword/`, `ForewordTests/`, `ForewordUITests/` are auto-included.

### Scenes (`ForewordApp.swift`)

- Main `WindowGroup` mounts `SidebarView` (tab host + toolbar Refresh, in-flight indicator, "Active review" pill).
- `Window("Review", id: ReviewWindowID.main)` hosts `ReviewSheet`. A standalone window, not a `.sheet`, so the main window stays resizable while a review is open. Opened via `openWindow(id: ReviewWindowID.main)`.
- `Settings { SettingsView() }` for the standard `⌘,` panel.
- `MenuBarExtra` companion with at-a-glance counts (`MenuBarCounts.shared`).
- Single `ModelContainer` for `[Review, Finding, CachedJiraTicket, PreReviewSummary]`, stored at `~/Library/Application Support/Foreword/default.store`. Falls back to in-memory if the on-disk container fails to load. Under XCTest the app uses an in-memory store and skips legacy migration.

### Tabs and views (`Views/`)

- `SidebarView.swift` — `AppTab` enum: **Reviews**, **My PRs**, **Sessions**. Holds the per-tab view models (`TabViewModels.swift`) so loaded state survives tab switches.
- `ReviewsTab.swift` — review-requested PRs, approvals filter, dismissed toggle, reviewed-by-me sub-sections (Changes Requested / My Comments / Already Approved), "N new commits since your review", per-card **Review** / **Summarize** actions, Jira badge, manual evict.
- `MyPRsTab.swift` — authored PRs with per-reviewer state, unresolved threads (awaiting you / replied), comment counts.
- `SessionsTab.swift` — native session reader (`SessionsReader`; reads `~/.claude/sessions/` and `~/.claude/history.jsonl` directly, no `claude-sessions.js`).
- `ReviewSheet.swift` — content of the Review window: live stream, verdict / summary / Jira alignment, findings grouped by severity with Open / Resolved / Dismissed state, per-`headSha` history, Re-review, Cancel. Click on a finding → `IntelliJLauncher.openWithFallback`.
- `SettingsView.swift` — GitHub, Jira, Tools (binary paths + bundled skill), Behavior (concurrency cap, review timeout, project key prefixes, extra env vars), Appearance, Review Prompt template editor with live preview, Pre-Review Summary concurrency, Local Repos, Storage (disk usage / per-repo evict), re-run the wizard.
- `FirstRunWizard.swift`, `TokenPromptSheet.swift` — onboarding. The wizard owns the consented `gh auth token` bootstrap; nothing shells out to `gh` for a token without a click.
- `MenuBarContent.swift`, `JiraBadgeView.swift`, `ReviewerAvatarView.swift`, `ReviewSkillRow.swift` — smaller components.

### Review pipeline (`Services/ReviewOrchestrator.swift`)

`start(...)` first runs `GitHubRepoSpec.validate` / `GitBranchSpec.validate` (repeated inside `WorktreeManager.prepare`) so malformed repo identifiers and branch names never reach git. Then `runRealPipeline(input:)`:

1. `WorktreeManager.prepare` — creates the per-PR worktree at `~/.foreword/worktrees/<org>/<repo>/<pr#>/`. If `LocalRepoIndex` maps the repo to a clone under the Local Repos search roots (default `~/src`), the worktree is created from that clone; otherwise from a bare clone at `~/.foreword/repos/<org>/<repo>.git`.
2. `TicketKeyExtractor.extract(branchName:projectKeyPrefixes:)` → `JiraClient.fetchTicket` (cached in `CachedJiraTicket`; thin subtasks also fetch the parent).
3. `fetchChangedFiles(repo:prNumber:)` shells `gh pr view --json files --jq '.files[].path'` for the prompt allowlist (degrades to no-allowlist on failure).
4. `OrchestratorPrompt.build` composes: Jira block → user template (interpolated `{{repo}} {{prNumber}} {{branch}} {{sha}}`) → schema directive → allowlist block.
5. `ClaudeRunner.run` spawns `claude` with `cwd = worktree`, `allowedTools = "Read,Grep,Glob,Skill,Bash(gh:*),Bash(git:*)"`, `disallowedTools = "Bash,Write,Edit,Task,TodoWrite,WebFetch,WebSearch"`, timeout `AppSettings.reviewTimeoutMinutes` (default 30). Yields a stream of `ClaudeEvent`.
6. `ReviewStore.markCompleted` parses the final result against `ReviewSchema`, filters findings whose `file` is missing in the worktree (or absolute / empty), persists kept findings, surfaces drop count via `Review.errorMessage`.

Cancellation flows through `CancellationContext` → `CancellationFlag` (lock-backed) → SIGTERM via `ProcessBox`. Concurrency capped per `AppSettings.concurrencyCap` (default 3) with queue + drain in the orchestrator.

`ClosedPRDetector` runs after each Reviews refresh: any PR with stored Reviews that no longer shows up in `review-requested:@me` / `reviewed-by:@me` is treated as closed (so does a PR you were un-requested from without reviewing), and its worktree, Reviews, Findings and Pre-Review Summaries are dropped (the backing clone is kept).

### Pre-Review Summary pipeline (`Services/PreReviewSummary*.swift`)

Separate from the review pipeline (see `docs/adr/0002-pre-review-summary-separate-pipeline.md`). No worktree. `Bash(gh:*)` only, file tools denied, user MCP servers suppressed (`--mcp-config '{"mcpServers":{}}'`), 180s timeout. Output schema is a single `text` field (2–4 sentences of plain prose on what / why / risk). Cached forever per `headSha` in `PreReviewSummary.text`. Runs on its own concurrency pool (`AppSettings.summaryConcurrencyCap`, default 5). `PreReviewSummaryOrchestrator` is still an `ObservableObject`; `ReviewOrchestrator` is `@Observable`.

### GitHub networking

`GitHubClient` plus topic extensions (`+MyPRs`, `+Reviews`, `+PRBranch`) all go through `HTTPClient`: shared auth headers and decoder, ETag / `If-None-Match` via a shared `URLCache`, typed errors (`rateLimited`, `forbidden`, `notFound`, `graphqlPartial`), retry with backoff for transient failures, `Link: rel="next"` pagination with a 5-page ceiling.

### Critical paths

- Worktree layout: `~/.foreword/repos/<org>/<repo>.git` (bare) and `~/.foreword/worktrees/<org>/<repo>/<pr#>/` (per-PR, same location whether backed by a bare clone or a local clone). `WorktreePath.url(for:prNumber:)` is the single source of truth.
- Legacy name: the app used to be `WorkHomepage`. `LegacyDataMigration.runIfNeeded()` (first thing in `ForewordApp.init`) moves `Application Support/WorkHomepage/` and `~/.work-homepage/` to the new locations (repairing git worktree links) and copies Keychain items from service `com.work-homepage` to `io.github.nakielsh.foreword`. Never overwrites data already at the new location.
- Bundled skills: repo-root `skills/` is a folder reference copied into `Foreword.app/Contents/Resources/skills/`. The default review prompt invokes `reviewing-pr-final-state`; `BundledSkillInstaller` copies it into `~/.claude/skills/` from the first-run wizard / Settings (never overwrites). Edit the skill in `skills/`, not in the prompt.
- Shelled binaries: `git`, `gh`, `claude`, `idea`. All resolved via `BinaryResolver` from a fixed candidate list (Homebrew, `/usr/local/bin`, `/usr/bin` for git, `~/.claude/local` for claude, JetBrains Toolbox scripts / IntelliJ app bundle for idea) or a user override. No shell PATH inheritance — the app is GUI-launched.
- Child env differs per binary:
  - `idea` (`IntelliJLauncher`): `ShellEnvironment.filteredForChildren()` captures the user's interactive shell env via `$SHELL -ilc env`, then allow-lists keys. Built-in allow-list passes `HOME, USER, LOGNAME, PATH, SHELL, LANG, TZ, TMPDIR, TERM, JAVA_HOME, SSH_AUTH_SOCK, SSH_AGENT_PID` plus `JAVA_*`, `GRADLE_*`, `MAVEN_*`, `LC_*` prefixes. Users add their own (e.g. private repository credentials) in Settings → Behavior → "Forward extra environment variables" (`AppSettings.extraEnvKeys` / `extraEnvPrefixes`; `FOO_*` = prefix). Anything else (e.g. `ANTHROPIC_API_KEY`, AWS creds) is dropped.
  - `claude` (`ClaudeRunner.buildClaudeEnv`, shared by both pipelines): `HOME, USER, TERM, LANG`, a PATH built from the resolved tool directories, and any `ANTHROPIC_*` / `CLAUDE_*` variables in Foreword's own process environment (not the captured shell env).
  - `git` (`WorktreeManager.runProcessSync`) and `gh auth token` (`GitHubTokenBootstrap`): `HOME, USER` (+ `TERM` for git) and a fixed PATH.

## Build, install, test

```sh
# Build + copy to /Applications + reset IconServices cache so Stage Manager picks up new app icon.
make local-install

# Quick build only.
make build

# Run every test target, including ForewordUITests (drives the real app and takes over the screen).
make test

# Unit tests only (what CI runs).
xcodebuild test \
  -project Foreword/Foreword.xcodeproj \
  -scheme Foreword \
  -destination 'platform=macOS' \
  -only-testing:ForewordTests

# Run a targeted suite.
xcodebuild test \
  -project Foreword/Foreword.xcodeproj \
  -scheme Foreword \
  -destination 'platform=macOS' \
  -only-testing:ForewordTests/ReviewStoreFilterTests

# Remove stale per-worktree DerivedData copies that show up as extra "Foreword" apps in Spotlight.
make clean-derived-data

# Before opening a PR (CI runs it too).
./scripts/check-no-org-leaks.sh
```

Local install and the signing / notarization recipe for distributing your own build are in `docs/release.md`. `make local-install` is enough to run the app on your own Mac. The app icon set is generated by `scripts/make-app-icon.py` (see `CONTRIBUTING.md`).

## Conventions

- **Static imports only** — no wildcard imports anywhere.
- **Tests use AssertJ-style helpers** in `ForewordTests/Helpers/Assertions.swift` (`assertThat(x).isEqualTo(y)`, `.contains(...)`, `.hasSize(...)`). Prefer over raw `XCTAssertEqual` where a chain reads cleaner. `Helpers/URLProtocolStub.swift` and `Helpers/PollUntil.swift` are the shared stubs / async helpers.
- **Tests never touch real user data** — use `UserDefaults(suiteName:)`, a temp directory, or a unique Keychain service.
- **Models live in `Foreword/Foreword/Models/`**; SwiftData `@Model` classes only there. Decoded API shapes (e.g. `ReviewSchema`, `SchemaFinding`) live in `Services/` next to the code that produces them.
- **GitHub API calls** go through `GitHubClient` with topic extensions (`+MyPRs`, `+Reviews`, `+PRBranch`), all on top of `HTTPClient`.
- **Untrusted content** (branch names, Jira summaries / descriptions, parent description, anything user-controlled or upstream-controlled) is wrapped via `UntrustedContent.fence(_:label:)` / `.sanitise(_:)` (in `ReviewOrchestrator.swift`) before it reaches the prompt builder. Defence-in-depth on top of `--allowed-tools` / `--disallowed-tools`.
- **Theme** — colors come from the asset catalog's generated symbols (`Color.bgDeep`, `Color.accentFern`, `Color.textSecondary`, …); fonts from `Font.display(size:)` / `Font.appBody(size:)` / `Font.mono(size:)` in `Theme.swift`. Light values mirror the `:root` tokens in `index.html`; dark derivation is in ADR-0001.
- **Don't post to GitHub** — Reviews stay local-only by design. The orchestrator writes to SwiftData and that's it.

## Legacy HTML dashboard

**`index.html`** — the whole thing: HTML, CSS (in `<style>`), and JS (in `<script>`). Runs as a local `file://` page, no build step. Same Botanical Garden theme as the app.

Three tabs:

- **Reviews** — PRs assigned for review (`review-requested:@me`). Filter dropdown ("Hide PRs with >= N approvals"), dismissed-reviews toggle, stats bar, sub-sections for `reviewed-by:@me` (Changes Requested, My Comments, Already Approved), "N new commits since your review" badge.
- **My PRs** — Authored open PRs. Per-reviewer status badges, unresolved-thread counts (GraphQL), total comment counts.
- **Claude Code** — Active sessions from `claude-sessions.js` (`window.__claudeSessions`).

Data: GitHub REST + GraphQL; token in `localStorage`; filter state + active tab also in `localStorage`. Card rendering uses DOM creation, not templates; `renderReviewCards(grid, prs)` is shared between the pending-reviews section and the three reviewed-by-me sub-sections.

**Refresh pipeline** for the Claude Code tab (the macOS app doesn't use any of this):

- `refresh-sessions.py` reads `~/.claude/sessions/*.json`, validates PIDs via `os.kill(pid, 0)`, pulls the last user prompt per session from `~/.claude/history.jsonl` (truncated to 200 chars), writes `claude-sessions.js` (gitignored) next to itself.
- `refresh-sessions.sh` is the wrapper invoked by launchd; runs the script with `/usr/bin/python3`.
- `refresh-claude-sessions.plist.template` is the LaunchAgent template — replace `__INSTALL_DIR__` and `launchctl load`. Runs every 120s + on login. Logs to `/tmp/refresh-claude-sessions.log`.

## Where to look

- User-facing overview → `README.md`. Threat model → `SECURITY.md`. Contributor setup → `CONTRIBUTING.md`.
- Domain glossary → `CONTEXT.md`.
- Original product story (historical, pre-rename) → `docs/PRD.md`.
- Architecture decisions → `docs/adr/`.
- Slice-by-slice implementation history → `docs/issues/`.
- Code-review follow-ups & known TODOs → `docs/review-followups.md`.
- Local install, signing & notarization → `docs/release.md`.
