# Open-Source Readiness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn `work-homepage` into a project-agnostic, publishable open-source repo under a new name: no Ala-com / employer-specific code, config, fixtures or docs at HEAD.

**Architecture:** Snapshot the current internal state on branch `ala-com` (done). On `main`, delete the Deployments feature outright (it's the only org-hardwired feature), neutralise every org identifier in tests/docs, rename the app, move build identity (Team ID, bundle id) out of the checked-in project, generalise the few stack-specific assumptions (Java/Gradle env allow-list, IntelliJ-only launcher, branch-name ticket regex), bundle the review skill the default prompt depends on. History is **kept as-is** (D5): cleanup lands as normal commits on top; old commits still contain the identifiers listed in §1.6.

**Tech Stack:** SwiftUI + SwiftData (macOS), XCTest, single-file HTML/JS dashboard, Python 3 refresher, GitHub Actions (new).

---

## 0. State on 2026-10-01

- Branch `ala-com` created locally from `main` @ `a2f717b`. **Not pushed.** Holds the full internal version (Deployments, Ala-com services, Barto release docs, presentation).
- Existing branches that must never reach a public remote: `ala-com`, `backup/pre-rewrite` (commits authored as `@ala.com`), all `worktree-agent-*`.
- Remote `origin` = `github.com/nakielsh/work-homepage`, **private**.
- Untracked: `.agents/`, `skills-lock.json` (HyperFrames skills used to build `presentation.html`; unrelated to the app).

## 1. Audit findings

Severity: **P0** = leaks employer identity or blocks a stranger from using the app. **P1** = works but clearly someone else's setup. **P2** = polish.

### 1.1 Org-hardwired feature: Deployments (P0) → delete

The only feature that can't work outside Ala-com. Hardcoded org, workflow name, service list, and repo naming scheme.

| Where | What |
|---|---|
| `WorkHomepage/WorkHomepage/Services/DeploymentsConfig.swift:13-36` | `org = "Ala-com"`, `workflow = "Deploy to EKS from ECR"`, 10 service names (`account`, `worker`, `rental`, `model_gateway`, `rag_atlassian_plugin`, …), `serviceToRepo` → `backend-<svc>` |
| `Services/DeploymentsParser.swift`, `Services/GitHubClient+Workflows.swift`, `Models/Deployment.swift`, `Models/WorkflowRun.swift`, `Views/DeploysTab.swift` | Feature implementation |
| `Views/SidebarView.swift:27,36,55,118-119` | `AppTab.deploys`, `deploysVM`, detail switch |
| `Views/TabViewModels.swift:34-49` | `DeploysViewModel`, `DeployServiceCardState` |
| `WorkHomepageTests/DeploymentsParserTests.swift`, `WorkflowRunsDecodingTests.swift` | Tests, contain `Ala-com/backend-account` URLs |
| `WorkHomepageUITests/WorkHomepageUITests.swift:52-53` | Asserts a "Deploys" sidebar item |
| `index.html` CSS `615-684`, tab button `906-908`, panel `1010-1019`, JS `1202-1218`, `1808-2000` | HTML Deployments tab + `DEPLOY_ORG`/`SERVICES` |
| `README.md:3,58-66`, `CLAUDE.md:12,25,50`, `CONTEXT.md:7`, `docs/PRD.md:83,245`, `docs/issues/05-deployments-tab-parity.md` | Docs |

Generalising it (configurable org/workflow/services + run-name parser) is possible but the run-name format (`DeploymentsParser`) is itself Ala-com's convention. Not worth it for v1 — delete. Can come back later as an opt-in "Workflow runs" tab.

### 1.2 Org identifiers in code, tests, docs (P0)

| Pattern | Count | Where | Action |
|---|---|---|---|
| `Ala-com` | 93 lines | doc comments in `MyPRsModels.swift:88`, `PullRequest.swift:32`, `WorktreeManager.swift:96`, `WorktreePath.swift:24`; live-preview stub `SettingsView.swift:428`; ~20 test files; `README.md`, `PRD.md`, issues 05 & 23 | Replace with `acme` (`acme/widgets`, `acme/foo`) |
| `JWT-123`, `JWT-1`, `"JWT, ABC, XYZ"` | 175 | Jira key examples across models, `SettingsView.swift:332,419,430`, tests, `CONTEXT.md`, docs. `JWT` is Ala-com's Jira project key | Replace with `PROJ-123`; placeholder `"PROJ, ABC"` |
| `backend-rag`, `backend-account`, `backend-worker`, `backend-rental` | 19 | `IdeaProjectSyncTests.swift:58-81`, Workflow tests, `presentation.html` | Replace with `widgets` / gone with Deployments |
| `com.floc.*` bundle ids | 6 | `project.pbxproj:419,464,492,513,532,551`, `docs/release.md:183` | New neutral id (see §1.4) |
| `DEVELOPMENT_TEAM = 7Y7HCMY4K5` | 8 + 4 in docs | `project.pbxproj`, `docs/release.md:67,98,113,160` | Remove from project; per-dev `Local.xcconfig` |
| Rippling Barto | 13 | `docs/release.md` Phase 2, `CLAUDE.md:98,118` | Drop Barto section; keep generic Developer-ID/notarize notes |
| `REPO_USER`, `REPO_PASSWORD`, `ARTIFACTORY_*` | 15 | `ShellEnvironment.swift:71-76` allow-list, tests, `CLAUDE.md:77`, `IntelliJLauncher.swift:277-292` comments | Employer's Artifactory creds convention → move to user-configurable extra keys (§1.3) |
| `presentation.html` | 2019 lines | Internal talk: Ala-com paths, service names, author name | Remove from `main` (stays on `ala-com`) |
| Personal path `/Users/Hubert-ale/...` | 1 | `PathFormatterTests.swift:39` | → `/Users/jane/...` |
| GitHub login `hubert` | 2 | `GitHubClientMyPRsTests.swift:48,81` | → `octocat` |

No API tokens / keys found in tracked files or in any branch's history (scanned for `ghp_`, `github_pat_`, `ATATT`, `sk-ant-`, `xox[bp]-`, `AKIA`). Only placeholders.

### 1.3 Stack/workflow assumptions baked in (P1)

| Assumption | Where | Problem for strangers | Action |
|---|---|---|---|
| Default review prompt calls `reviewing-pr-final-state` skill | `ReviewPromptStore.swift:38` | Skill lives in the author's `~/.claude/skills/`. Nobody else has it → reviews silently degrade | **P0.** Vendor skill into repo, ship in app bundle, install on demand (Task 7) |
| Env allow-list hard-codes `REPO_USER`, `REPO_PASSWORD`, `ARTIFACTORY_` | `ShellEnvironment.swift:66-77` | Employer conventions; also forwards passwords to children by default | Keep generic base set (`HOME USER PATH SHELL LANG TZ TMPDIR TERM SSH_AUTH_SOCK SSH_AGENT_PID` + `LC_`, `JAVA_`, `GRADLE_`, `MAVEN_`); add "Extra env keys/prefixes" setting |
| IntelliJ is the only editor | `IntelliJLauncher.swift`, `IdeaProjectSync.swift`, `BinaryResolver` (`idea`), `ReviewSheet` click handler | Excludes VS Code / Cursor / Xcode / Zed users | v1: document as IntelliJ-first, fallback already opens file. v1.1: `EditorLauncher` protocol (Task 11, optional) |
| Ticket key only from `(feature\|bugfix\|hotfix\|chore\|task)/KEY-123` | `TicketKeyExtractor.swift:35` | Many teams use `KEY-123-foo`, `user/KEY-123`, or PR title | Make regex fall back to first `[A-Z][A-Z0-9]+-\d+` anywhere in branch when prefix form misses, gated by configured project-key prefixes (already in `AppSettings.projectKeyPrefixesKey`) |
| Jira = Atlassian Cloud only (v3 API, ADF) | `JiraClient.swift:307` | Jira Server/DC users | Document. Already skippable in first-run wizard |
| Default local repo root `~/src` | `LocalRepoIndex.swift:37-39` | Fine — configurable via `localRepoIndex.roots` | Document in README |
| `.idea/` sync assumes Gradle/Kotlin | `IdeaProjectSync.swift` | Harmless no-op without `.idea/` | Keep |

### 1.4 Build identity (P0)

- `PRODUCT_BUNDLE_IDENTIFIER = com.floc.WorkHomepage*` → pick neutral, e.g. `io.github.nakielsh.WorkHomepage` (decide in §2).
- `DEVELOPMENT_TEAM = 7Y7HCMY4K5` checked in → contributors can't build signed without editing the pbxproj. Move to `Config/Local.xcconfig` (gitignored) included from `Config/Base.xcconfig`; default empty → "Sign to Run Locally".
- Side effect for **your** install: UserDefaults domain follows bundle id → settings (Jira base URL, prompt template, caps, repo roots) reset. Keychain service is `com.work-homepage` (`KeychainStore.swift:12`) — survives, but macOS will prompt once because the signing identity changes. SwiftData store is `Application Support/WorkHomepage/` — survives. Migration: `defaults export com.floc.WorkHomepage - | defaults import <new-id> -`.

### 1.5 Repo hygiene (P1/P2)

| Item | Action |
|---|---|
| No `LICENSE` | Add (MIT or Apache-2.0 — §2) |
| Bundled fonts (Libre Baskerville, Source Sans 3) are SIL OFL 1.1 | Add `WorkHomepage/WorkHomepage/Resources/Fonts/OFL.txt` + attribution in README |
| App icon provenance | Confirm it's yours / generated; note in README |
| `docs/issues/01-26`, `docs/PRD.md` | Fine to publish (good design history) after §1.2 scrub. PRD has internal framing ("my coworkers"), OK |
| `docs/review-followups.md` | Mentions two failing tests (`MonogramRendererTests`) — fix or mark skipped before CI goes green |
| `CLAUDE.md` | Keep (useful for contributors using Claude Code); scrub Barto, Deployments, Artifactory lines |
| `.gitignore` | Add `Config/Local.xcconfig`, `.agents/`, `skills-lock.json` |
| `README.md` | Currently describes HTML page first, app second. Rewrite app-first with screenshots, requirements (`gh`, `claude`, optional `idea`, optional Jira), install, privacy/trust model |
| No CI | Add GitHub Actions `macos-15` running `make test` |
| No `SECURITY.md` | App spawns `claude` with tool access against untrusted PR content — document threat model (`UntrustedContent.fence`, allowed/disallowed tools, env allow-list) and how to report |
| `index.html` dashboard | Keep, but generic (no Deployments). Or move to `web/` — §2 |

### 1.6 Git history (P0)

`main` history was already re-authored to the gmail address, but its **diffs** still contain `Ala-com` (109 hits), the Team ID, `com.floc`, Rippling Barto docs, the presentation, and service names. `backup/pre-rewrite` still has `@ala.com` authorship.

Options:

1. **Fresh public repo from a squashed snapshot (recommended).** One orphan commit of the cleaned tree → push to a *new* public repo. Zero leak risk, trivial to verify. Cost: lose 103 commits of history (still kept in the private repo; `docs/issues/` preserves the narrative).
2. `git filter-repo --replace-text` + path removals on a clone. Keeps history, but every past blob must be scrubbed (pbxproj Team IDs, deleted `xcuserdata` with `Hubert-ale`, presentation, Barto). Easy to miss one; needs a second audit of every blob.
3. Flip current repo to public with only `main` pushed. Keeps history; old commits stay readable.

**Chosen (2026-10-01): keep history, no squash, no rewrite.** Cleanup is committed on top of `main`. Accepted consequence: anyone browsing history of the public repo can read the identifiers above in old commits. Mitigations that still apply: push **only** `main` to the public remote; never push `ala-com`, `backup/pre-rewrite`, `worktree-agent-*`.

## 2. Decisions

| # | Question | Status |
|---|---|---|
| D1 | License | **Open** — MIT recommended |
| D2 | App / repo name | **Open** — new name wanted, candidates TBD (Task 4a) |
| D3 | Bundle id | **Decided:** `io.github.nakielsh.<NewName>` |
| D4 | HTML dashboard | Keep at root, Deployments removed |
| D5 | History | **Decided:** keep history, commit cleanup on top (§1.6 option 3) |
| D6 | `ala-com` backup | **Decided:** separate local branch for now; not pushed |
| D7 | Editor abstraction (Task 11) | Post-launch |
| D8 | Employer sign-off | **Open** — early commits were authored with the work address; confirm with Ala-com that publishing is OK before going public |

## 3. Tasks

Run `make test` after each task. Commit per task on a branch `oss/prep` off `main`.

### Task 1: Remove Deployments from the macOS app

**Files:**
- Delete: `WorkHomepage/WorkHomepage/Services/DeploymentsConfig.swift`, `Services/DeploymentsParser.swift`, `Services/GitHubClient+Workflows.swift`, `Models/Deployment.swift`, `Models/WorkflowRun.swift`, `Views/DeploysTab.swift`
- Delete: `WorkHomepage/WorkHomepageTests/DeploymentsParserTests.swift`, `WorkHomepageTests/WorkflowRunsDecodingTests.swift`
- Modify: `Views/SidebarView.swift:23-38,55,118-119`, `Views/TabViewModels.swift:33-49`, `WorkHomepageUITests/WorkHomepageUITests.swift:52-53`

Synchronized folder groups → deleting files is enough; no pbxproj edits.

**Step 1:** Update UI test first so it fails against the current app:

```swift
// WorkHomepageUITests.swift:52-53
// "Reviews", "My PRs", "Sessions". We don't pin pixel order — only membership.
for label in ["Reviews", "My PRs", "Sessions"] {
```
plus assert `app.staticTexts["Deploys"].exists == false`.

**Step 2:** `git rm` the eight files above.

**Step 3:** `SidebarView.swift` — drop `case deploys`, its `systemImage` arm, `deploysVM`, and the `.deploys` detail arm. `TabViewModels.swift` — drop `DeploysViewModel` + `DeployServiceCardState` and the header-comment mention.

**Step 4:** Verify:
```sh
make build
git grep -n -i -E "deploy|workflowrun" -- WorkHomepage   # expect: only unrelated hits (e.g. a test PR title "Wire deploy badges" → rename it too)
make test
```

**Step 5:** Commit `Remove Deployments tab from macOS app`.

### Task 2: Remove Deployments from `index.html`

**Files:** `index.html` (CSS `615-684`, tab `906-908`, panel `1010-1019`, refs `1202-1218`, JS `1808-2000`), `README.md:3,58-66`

**Step 1:** Delete those blocks; remove `deployments` from tab switching / count logic / `localStorage` active-tab restore (fall back to `reviews` if stored tab no longer exists).
**Step 2:** `grep -n -i deploy index.html` → 0 hits. Open `index.html`, click all three tabs, no console errors.
**Step 3:** README: drop "Org-specific customization" section and Deployments from the intro.
**Step 4:** Commit.

### Task 3: Neutralise fixtures, comments and placeholders

**Files:** all hits from §1.2 rows `Ala-com`, `JWT-`, `backend-*`, `hubert`, `/Users/Hubert-ale`.

**Step 1:** Mechanical replace (review the diff, don't trust blindly):
```sh
git grep -l "Ala-com" | xargs sed -i '' 's/Ala-com/acme/g'
git grep -l "JWT-" | xargs sed -i '' 's/JWT-/PROJ-/g'
sed -i '' 's/"JWT, ABC, XYZ"/"PROJ, ABC"/' WorkHomepage/WorkHomepage/Views/SettingsView.swift
sed -i '' 's/backend-rag/widgets/g' WorkHomepage/WorkHomepageTests/IdeaProjectSyncTests.swift
sed -i '' 's#/Users/Hubert-ale/src/ai/work-homepage#/Users/jane/src/widgets#' WorkHomepage/WorkHomepageTests/PathFormatterTests.swift
sed -i '' 's/"hubert"/"octocat"/' WorkHomepage/WorkHomepageTests/GitHubClientMyPRsTests.swift
```
Fix `PathFormatterTests` expected values to match the new input.

**Step 2:** `TicketKeyExtractorTests` — any test that relied on `JWT` specifically must still pass with `PROJ` (`[A-Z]+-\d+` covers both).
**Step 3:** `make test` → green. Commit.

### Task 4a: Rename the app to `<NewName>`

Blocked on D2. Do it before Task 4 so the bundle id is set once.

**Files / touch points:**
- Xcode: project dir `WorkHomepage/`, `.xcodeproj`, targets `WorkHomepage` / `WorkHomepageTests` / `WorkHomepageUITests`, scheme, `PRODUCT_NAME`, `WorkHomepageApp.swift` (type + file), every `@testable import WorkHomepage`
- String literals: `SidebarView.swift:64` (`navigationTitle`), `FirstRunWizard.swift:109`, `MenuBarContent.swift:29,37` (window ids), `WorkHomepageApp.swift:50` (`Logger` subsystem)
- On-disk state (needs migration, see Step 3): `WorkHomepageApp.swift:67` (`Application Support/WorkHomepage/` SwiftData store), `WorktreePath.swift:28` + `WorktreeManager.swift:389` (`~/.work-homepage/` clones + worktrees), `KeychainStore.swift:12` (service `com.work-homepage`)
- Build/scripts: `Makefile` (`XCODEPROJ`, `SCHEME`, `APP_NAME`, `clean-derived-data` glob), `refresh-claude-sessions.plist.template:6` (label), `README.md`, `CLAUDE.md`, `docs/release.md`

**Step 1:** Rename project + targets + scheme in Xcode (Project navigator rename → accept "rename related items"), then `make build` and `make test`.
**Step 2:** Replace string literals above; `git grep -n -i -E "work-?homepage"` → only historical docs (`docs/issues/`, `docs/PRD.md`) and the migration code.
**Step 3 (test first):** `LegacyDataMigrationTests` — on first launch, if new locations are empty and legacy ones exist: move `Application Support/WorkHomepage/` → `Application Support/<NewName>/`, move `~/.work-homepage/` → `~/.<new-name>/` (skip if worktrees are in use), copy Keychain items from service `com.work-homepage` to the new service. Never overwrite existing new-location data.
**Step 4:** Implement `LegacyDataMigration.runIfNeeded()` called from the app's `init` before `ModelContainer` is built.
**Step 5:** `make local-install`, remove old `/Applications/WorkHomepage.app`, confirm reviews, findings, Jira creds and GitHub token survived. Commit.

### Task 4: Build identity out of the project file

**Files:**
- Create: `WorkHomepage/Config/Base.xcconfig`, `WorkHomepage/Config/Local.xcconfig.example`
- Modify: `WorkHomepage/WorkHomepage.xcodeproj/project.pbxproj` (6× bundle id, 8× `DEVELOPMENT_TEAM`), `.gitignore`

```xcconfig
// Config/Base.xcconfig
BUNDLE_ID_PREFIX = io.github.nakielsh
DEVELOPMENT_TEAM =
#include? "Local.xcconfig"
```
```xcconfig
// Config/Local.xcconfig.example — copy to Local.xcconfig (gitignored)
DEVELOPMENT_TEAM = ABCDE12345
BUNDLE_ID_PREFIX = com.example
```

**Step 1:** In Xcode set `Base.xcconfig` as the base configuration for all targets/configs; in pbxproj set `PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).<NewName>` (and `…Tests`, `…UITests`), delete `DEVELOPMENT_TEAM = 7Y7HCMY4K5;` lines.
**Step 2:** Create your own `Local.xcconfig` with the real team ID; `make build` signs as before.
**Step 3:** Fresh clone without `Local.xcconfig` → `make build` succeeds (ad-hoc signing).
**Step 4:** Migrate your settings once: `defaults export com.floc.WorkHomepage - | defaults import io.github.nakielsh.<NewName> -`.
**Step 5:** `git grep -n -E "7Y7HCMY4K5|com\.floc"` → 0. Commit.

### Task 5: Generalise child-process env allow-list

**Files:** `Services/ShellEnvironment.swift:60-80`, `Services/AppSettings.swift`, `Views/SettingsView.swift`, `WorkHomepageTests/ShellEnvironmentTests.swift:100-118`

**Step 1 (test first):** `testFiltersEmployerSpecificKeysByDefault` — `REPO_USER`, `REPO_PASSWORD`, `ARTIFACTORY_TOKEN` are dropped with default settings; `testForwardsUserConfiguredExtraKeysAndPrefixes` — with `extraEnvKeys = ["REPO_USER"]`, `extraEnvPrefixes = ["ARTIFACTORY_"]` they pass.
**Step 2:** Run → fail.
**Step 3:** Remove `REPO_USER`, `REPO_PASSWORD` from the exact-key set and `ARTIFACTORY_` from prefixes; add `AppSettings.extraEnvKeys` / `extraEnvPrefixes` (`[String]`, UserDefaults); `filteredForChildren()` unions them in. Settings → "Advanced → Forward extra environment variables" text field (comma-separated).
**Step 4:** Tests pass. Set your own extras in Settings so IntelliJ/Gradle keeps working. Update `CLAUDE.md:77`. Commit.

### Task 6: Looser ticket-key extraction

**Files:** `Services/TicketKeyExtractor.swift`, `WorkHomepageTests/TicketKeyExtractorTests.swift`, call sites passing `AppSettings` prefixes.

**Step 1 (tests):** `feature/PROJ-12-x` → `PROJ-12` (unchanged); `PROJ-12-add-thing` → `PROJ-12` when `PROJ` is a configured prefix; `jane/PROJ-12` → `PROJ-12` when configured; `UTF-8-fix` → nil when `UTF` not configured; `main` → nil.
**Step 2:** Implement: keep strict prefix regex as first try; fallback `\b([A-Z][A-Z0-9]+-\d+)\b` accepted only if the key's project part is in configured prefixes.
**Step 3:** Tests pass. Commit.

### Task 7: Bundle the `reviewing-pr-final-state` skill

**Files:**
- Create: `skills/reviewing-pr-final-state/SKILL.md` (copy from `~/.claude/skills/reviewing-pr-final-state/`, scrub anything org-specific)
- Modify: Xcode target → add `skills/` as a bundle resource; `Views/SettingsView.swift` + `Views/FirstRunWizard.swift` (install button + status); `Services/ReviewPromptStore.swift:38`
- Create: `Services/BundledSkillInstaller.swift`, `WorkHomepageTests/BundledSkillInstallerTests.swift`

**Step 1 (tests):** installer copies bundled skill into a temp `skillsRoot` when absent; never overwrites an existing dir; reports `.installed / .alreadyPresent / .failed`.
**Step 2:** Implement `BundledSkillInstaller.install(into: URL = ~/.claude/skills)`.
**Step 3:** First-run wizard + Settings show "Review skill: installed / Install". Default template keeps the skill invocation (per skill-over-inline-prompt convention) but add one fallback line: "If the skill is unavailable, review the full PR diff against its base branch (`gh pr diff {{prNumber}} --repo {{repo}}`)."
**Step 4:** Commit.

### Task 8: Docs scrub

**Files:** `docs/release.md` (delete "Phase 2 — Rippling Barto" sections lines `50-206` → replace with generic "Signing & notarizing your own build"; strip Team ID), `CLAUDE.md` (Deployments, Barto, Artifactory lines), `CONTEXT.md:7,34`, `docs/PRD.md:83,245,310`, `docs/issues/05-*.md` (add header "Removed in open-source release"), `docs/issues/23-*.md`, `docs/issues/README.md`.
Delete: `presentation.html`.
Commit.

### Task 9: OSS scaffolding

**Files (create):** `LICENSE`, `WorkHomepage/WorkHomepage/Resources/Fonts/OFL.txt`, `CONTRIBUTING.md`, `SECURITY.md`, `.github/workflows/ci.yml`, `.github/ISSUE_TEMPLATE/bug_report.md`, `docs/screenshots/*.png`. **Rewrite:** `README.md`.

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - run: ./scripts/check-no-org-leaks.sh
      - run: xcodebuild test -project WorkHomepage/WorkHomepage.xcodeproj -scheme WorkHomepage -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

README sections: what it is (screenshot) · requirements (macOS 15+, `gh`, `claude` CLI, optional IntelliJ `idea`, optional Jira Cloud) · install (`make local-install`) · first run · how reviews work + what tools Claude gets · privacy (local-only, never posts to GitHub, Keychain, env allow-list) · HTML dashboard (secondary) · license/fonts.

Fix or skip the two failing `MonogramRendererTests` (`docs/review-followups.md:83`) so CI starts green. Commit.

### Task 10: Leak gate + final audit

**Files:** Create `scripts/check-no-org-leaks.sh`.

```bash
#!/usr/bin/env bash
# Fails if employer-specific identifiers reappear in tracked files.
set -euo pipefail
pattern='Ala-com|ala\.com|JWT-[0-9]|7Y7HCMY4K5|com\.floc|Barto|Rippling|backend-(account|worker|rental|rag)|Hubert-ale|REPO_PASSWORD'
if git grep -n -I -i -E "$pattern" -- . ':!scripts/check-no-org-leaks.sh'; then
  echo "Org-specific identifiers found (see above)." >&2
  exit 1
fi
```

**Step 1:** Run → expect exit 0.
**Step 2:** `gitleaks detect --source . --no-git` (brew install gitleaks) → no findings.
**Step 3:** Manual read-through of README, CLAUDE.md, CONTEXT.md, docs/PRD.md, Settings UI strings, default prompt.
**Step 4:** Commit; merge `oss/prep` → `main`.

### Task 11 (optional, post-launch): Editor abstraction

`EditorLauncher` protocol with `IntelliJLauncher`, `VSCodeLauncher` (`code -g file:line`), `CursorLauncher`, `XcodeLauncher` (`xed -l line file`), `DefaultAppLauncher` (`open`). Setting picks one; `BinaryResolver` resolves the matching binary; `ReviewSheet` click calls the selected launcher. Keeps `IdeaProjectSync` IntelliJ-only.

### Task 12: Publish

History kept (D5), so no orphan/squash. Before flipping visibility:

```sh
git ls-remote --heads origin           # must list only refs/heads/main
git ls-remote --tags origin            # review every tag
./scripts/check-no-org-leaks.sh        # HEAD is clean
gh repo rename <new-name> --repo nakielsh/work-homepage   # GitHub keeps a redirect from the old name
gh repo edit nakielsh/<new-name> --visibility public --accept-visibility-change-consequences
git remote set-url origin https://github.com/nakielsh/<new-name>.git
```

Never `git push --all` / `--mirror` to this remote: `ala-com`, `backup/pre-rewrite` and `worktree-agent-*` would go public. If `ala-com` needs an off-machine backup later, push it to a **separate private** repo, not to this one.

## 4. Out of scope

- Mac App Store (sandbox incompatible with shelling to `git`/`gh`/`claude`).
- GitLab / Bitbucket support.
- Jira Server/DC, Linear, GitHub Issues as ticket sources.
- Homebrew cask / notarized DMG for public download (follow-up once there are users).
