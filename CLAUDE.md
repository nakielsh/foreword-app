# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Two coexisting apps in one repo:

1. **`index.html` + `refresh-sessions.*`** — original single-page HTML dashboard. Runs as a local `file://` page, no build step.
2. **`Foreword/`** — SwiftUI + SwiftData macOS app. The active surface most new work targets. Adds Claude-driven PR reviews, Jira context, IntelliJ launcher, pre-review summaries, settings, and a menu-bar companion on top of what the HTML page does.

Both target the same domain (GitHub PRs, Claude Code sessions). The macOS app is the strategic direction; the HTML page is kept around because it's still useful and zero-cost to maintain.

For domain vocabulary (Review vs. GitHub review, Pre-Review Summary, Worktree, Jira Ticket / Parent, Review Prompt Template), see `CONTEXT.md`. For architecture decisions, see `docs/adr/`. For slice-by-slice implementation history, see `docs/issues/`.

## HTML dashboard

**`index.html`** — Entire app: HTML, CSS (in `<style>`), and JS (in `<script>`). Botanical Garden theme (Libre Baskerville + Source Sans 3 fonts, fern green / marigold / terracotta / cream palette).

Three tabs:

- **Reviews** — PRs assigned for review (`review-requested:@me`). Filter dropdown ("Hide PRs with >= N approvals"), dismissed-reviews toggle, stats bar, sub-sections for `reviewed-by:@me` (Changes Requested, My Comments, Already Approved), "N new commits since your review" badge.
- **My PRs** — Authored open PRs. Per-reviewer status badges, unresolved-thread counts (GraphQL), total comment counts.
- **Claude Code** — Active sessions from `claude-sessions.js` (`window.__claudeSessions`).

Data: GitHub REST + GraphQL; token in `localStorage`; filter state + active tab also in `localStorage`.

**Refresh pipeline** for the Claude Code tab:

- `refresh-sessions.py` reads `~/.claude/sessions/*.json`, validates PIDs via `os.kill(pid, 0)`, pulls the last user prompt per session from `~/.claude/history.jsonl` (truncated to 200 chars), writes `claude-sessions.js` next to itself.
- `refresh-sessions.sh` is the portable wrapper invoked by launchd.
- `refresh-claude-sessions.plist.template` is the LaunchAgent template — replace `__INSTALL_DIR__` and `launchctl load`. Runs every 120s + on login. Logs to `/tmp/refresh-claude-sessions.log`.

## macOS app

Xcode project at `Foreword/Foreword.xcodeproj`. SwiftUI scenes + SwiftData persistence. Uses synchronized folder groups, so files added under `Foreword/Foreword/`, `ForewordTests/`, `ForewordUITests/` are auto-included.

### Scenes (`ForewordApp.swift`)

- Main `WindowGroup` mounts `SidebarView` (tab host).
- `Settings { SettingsView() }` for the standard `⌘,` panel.
- `MenuBarExtra` companion with at-a-glance counts (`MenuBarCounts.shared`).
- Single `ModelContainer` for `[Review, Finding, CachedJiraTicket, PreReviewSummary]`. On-disk store; falls back to in-memory if the on-disk container fails to load.

### Tabs (`Views/`)

- `ReviewsTab.swift` — review-requested PRs + a "Review" action that opens the review modal.
- `MyPRsTab.swift` — authored PRs with reviewer + thread state.
- `SessionsTab.swift` — native session reader (no `claude-sessions.js` round-trip; reads `~/.claude/sessions/` directly).
- `ReviewSheet.swift` — modal showing the live stream, findings list, and Jira/summary panels. Click on a finding → `IntelliJLauncher.openWithFallback`.
- `SettingsView.swift` — first-run + reconfiguration surface (binary paths, Jira creds, review prompt template editor, concurrency cap, disk usage / per-repo evict).
- `FirstRunWizard.swift`, `TokenPromptSheet.swift` — onboarding.

### Review pipeline (`Services/ReviewOrchestrator.swift`)

`runRealPipeline(input:)`:

1. `WorktreeManager.prepare` — bare clone + worktree at `~/.foreword/repos/<org>/<repo>.git` and `~/.foreword/worktrees/<org>/<repo>/<pr#>`.
2. `TicketKeyExtractor.extract(branchName:projectKeyPrefixes:)` → `JiraClient.fetchTicket` (cached in `CachedJiraTicket`).
3. `fetchChangedFiles(repo:prNumber:)` shells `gh pr view --json files --jq '.files[].path'` for the prompt allowlist (degrades to no-allowlist on failure).
4. `OrchestratorPrompt.build` composes: Jira block → user template (interpolated `{{repo}} {{prNumber}} {{branch}} {{sha}}`) → schema directive → allowlist block.
5. `ClaudeRunner.run` spawns `claude` with `cwd = worktree`, `allowedTools = "Read,Grep,Glob,Skill,Bash(gh:*),Bash(git:*)"`, `disallowedTools = "Bash,Write,Edit,Task,TodoWrite,WebFetch,WebSearch"`. Yields a stream of `ClaudeEvent`.
6. `ReviewStore.markCompleted` parses the final result against `ReviewSchema`, filters findings whose `file` is missing in the worktree (or absolute / empty), persists kept findings, surfaces drop count via `Review.errorMessage`.

Cancellation flows through `CancellationContext` → `CancellationFlag` (lock-backed) → SIGTERM via `ProcessBox`. Concurrency capped per `AppSettings.concurrencyCap` with queue + drain in the orchestrator.

### Pre-Review Summary pipeline (`Services/PreReviewSummary*.swift`)

Separate from the review pipeline (see `docs/adr/0002-pre-review-summary-separate-pipeline.md`). No worktree. `Bash(gh:*)` only. Cached forever per `headSha` in `PreReviewSummary`. Runs on its own concurrency pool.

### Critical paths

- Worktree layout: `~/.foreword/repos/<org>/<repo>.git` (bare) and `~/.foreword/worktrees/<org>/<repo>/<pr#>/` (per-PR). `WorktreePath.url(for:prNumber:)` is the single source of truth.
- Legacy name: the app used to be `WorkHomepage`. `LegacyDataMigration.runIfNeeded()` (first thing in `ForewordApp.init`) moves `Application Support/WorkHomepage/` and `~/.work-homepage/` to the new locations (repairing git worktree links) and copies Keychain items from service `com.work-homepage`. Never overwrites data already at the new location.
- Bundled skills: repo-root `skills/` is a folder reference copied into `Foreword.app/Contents/Resources/skills/`. The default review prompt invokes `reviewing-pr-final-state`; `BundledSkillInstaller` copies it into `~/.claude/skills/` from the first-run wizard / Settings (never overwrites). Edit the skill in `skills/`, not in the prompt.
- Shelled binaries: `git`, `gh`, `claude`, `idea`, `/usr/bin/python3`. All resolved via `BinaryResolver` (no shell PATH inheritance — the app is GUI-launched).
- Child env: `ShellEnvironment.filteredForChildren()` captures the user's interactive zsh env via `$SHELL -ilc env`, then allow-lists keys for forwarding. Built-in allow-list passes `HOME, USER, LOGNAME, PATH, SHELL, LANG, TZ, TMPDIR, TERM, JAVA_HOME, SSH_AUTH_SOCK, SSH_AGENT_PID` plus `JAVA_*`, `GRADLE_*`, `MAVEN_*`, `LC_*` prefixes. Users add their own (e.g. private repository credentials) in Settings → Behavior → "Forward extra environment variables" (`AppSettings.extraEnvKeys` / `extraEnvPrefixes`; `FOO_*` = prefix). Anything else (e.g. `ANTHROPIC_API_KEY`, AWS creds) is intentionally dropped.

## Build, install, test

```sh
# Build + copy to /Applications + reset IconServices cache so Stage Manager picks up new app icon.
make local-install

# Quick build only.
make build

# Run the full XCTest suite.
make test

# Run a targeted suite.
xcodebuild test \
  -project Foreword/Foreword.xcodeproj \
  -scheme Foreword \
  -only-testing:ForewordTests/ReviewStoreFilterTests
```

Local install and the signing / notarization recipe for distributing your own build are in `docs/release.md`. `make local-install` is enough to run the app on your own Mac.

## Conventions

- **Static imports only** — no wildcard imports anywhere.
- **Tests use AssertJ-style helpers** in `ForewordTests/Helpers/Assertions.swift` (`assertThat(x).isEqualTo(y)`, `.contains(...)`, `.hasSize(...)`). Prefer over raw `XCTAssertEqual` where a chain reads cleaner.
- **Models live in `Foreword/Foreword/Models/`**; SwiftData `@Model` classes only there. Decoded API shapes (e.g. `ReviewSchema`, `SchemaFinding`) live in `Services/` next to the code that produces them.
- **GitHub API calls** go through `GitHubClient` (REST) with topic extensions (`+MyPRs`, `+Reviews`, `+PRBranch`).
- **Untrusted content** (branch names, Jira summaries / descriptions, parent description, anything user-controlled or upstream-controlled) is wrapped via `UntrustedContent.fence(_:label:)` / `.sanitise(_:)` before it reaches the prompt builder. Defence-in-depth on top of `--allowed-tools` / `--disallowed-tools`.
- **Card rendering in `index.html`** uses DOM creation, not templates. `renderReviewCards(grid, prs)` is shared between the pending-reviews section and the three reviewed-by-me sub-sections.
- **Theme tokens** (HTML) live in `:root` custom properties; the macOS app exposes the same palette via `Color.appBody` / `Color.bgSurface` etc. in extensions.
- **Don't post to GitHub** — Reviews stay local-only by design. The orchestrator writes to SwiftData and that's it.

## Where to look

- Domain glossary → `CONTEXT.md`.
- Product story → `docs/PRD.md`.
- Architecture decisions → `docs/adr/`.
- Slice-by-slice implementation history → `docs/issues/`.
- Code-review follow-ups & known TODOs → `docs/review-followups.md`.
- Local install, signing & notarization → `docs/release.md`.
