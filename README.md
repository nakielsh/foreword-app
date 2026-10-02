# Foreword

A macOS app for the pull requests waiting on you. It lists the PRs you've been asked to review and the ones you opened, and runs a [Claude Code](https://docs.anthropic.com/en/docs/claude-code) review of a PR in an isolated git worktree, with the linked Jira ticket as context. Findings stay on your machine; click one to jump to the file and line in IntelliJ.

What's in the window:

- **Reviews**: PRs where your review is requested, plus the ones you already reviewed (changes requested, commented, approved) with "N new commits since your review".
- **My PRs**: PRs you authored, with each reviewer's state and unresolved thread counts.
- **Sessions**: Claude Code sessions currently running on your machine.
- A **Review** action on any PR that opens the review in its own window, a **Summarize** action for a short pre-review summary, Jira badges, and a menu-bar item with counts.

Foreword never posts anything to GitHub. Reviews are for you to read before you write your own.

## Requirements

- macOS 26.4 or later on Apple Silicon. Building needs Xcode 26.4 or later.
- [`gh`](https://cli.github.com/), signed in (`gh auth login`).
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`), signed in. Reviews run on your own Claude account.
- `git`.
- Optional: IntelliJ IDEA with the `idea` command-line launcher, for jump-to-line. Without it, clicking a finding opens the file in its default app.
- Optional: Jira Cloud (Atlassian-hosted) with an API token, for ticket context. Jira Server / Data Center isn't supported.

## Install

```sh
git clone https://github.com/nakielsh/foreword-app.git
cd foreword-app
make local-install
```

This builds a Release copy, signs it to run locally and copies it to `/Applications/Foreword.app`. To sign with your own Apple Developer team instead, see [docs/release.md](docs/release.md).

## First run

A setup sheet walks through five steps. Each can be skipped and changed later in Settings (⌘,):

1. **GitHub token**: read from `gh auth token` when you click the button, or pasted. Stored in the macOS Keychain.
2. **Jira**: site URL (`https://<you>.atlassian.net`), email and API token. Keychain again.
3. **Tools**: where `git`, `gh`, `claude` and `idea` live, plus the review skill (below).
4. **Project key prefixes**: your Jira project keys, e.g. `PROJ, ABC`.
5. **Concurrency**: how many reviews may run at once.

### The review skill

The default review prompt asks Claude to use the `reviewing-pr-final-state` skill. It scopes the review to what GitHub's *Files changed* tab shows: the right base branch, a three-dot diff, no reading of intermediate commits. Foreword ships a copy and installs it into `~/.claude/skills/` when you click **Install** in the setup sheet or Settings. An existing copy is never overwritten, so you can edit yours freely. The source lives in [`skills/`](skills/).

## How a review works

1. **Worktree.** Foreword checks the PR head out into `~/.foreword/worktrees/<org>/<repo>/<pr>/`. If you already have a clone under one of your local repo roots (Settings → Local Repos, default `~/src`), the worktree is created from it; otherwise from a bare clone in `~/.foreword/repos/`.
2. **Jira ticket.** The key comes from the branch name: `feature/PROJ-123`, `bugfix/PROJ-123` and similar always work. Branches like `PROJ-123-fix` or `jane/PROJ-123` work for the project keys you listed in step 4. If the ticket is a thin subtask, its parent is fetched too.
3. **Prompt.** The ticket, then your review prompt template (editable in Settings), then the list of files the PR changes. Branch names and Jira text are fenced as untrusted content.
4. **Claude.** `claude` runs inside the worktree with read-only tools: `Read`, `Grep`, `Glob`, `Skill`, and `gh` / `git` commands. `Bash`, `Write`, `Edit`, web access and sub-agents are explicitly denied. A run is stopped after 30 minutes by default (Settings → Behavior → Review timeout).
5. **Findings.** The JSON result is checked against a schema. Findings that point at files that don't exist in the worktree are dropped. The rest are stored locally, grouped by severity, and can be marked resolved or dismissed.

Up to three reviews run at once (Settings → Behavior → Concurrency cap); the rest queue and can be cancelled. Reviewing again after new commits creates a new review; earlier ones stay under **History** in the review window.

When a PR you ran a review on drops out of your Reviews lists (usually because it was closed or merged), the next refresh deletes its worktree, its saved reviews and findings, and its pre-review summaries. The repo's clone is kept. Disk usage and per-repo eviction are in Settings → Storage.

### Pre-review summary

**Summarize** on a PR card asks Claude for two to four sentences on what the PR changes, why, and what deserves a careful look. It's a separate, cheaper pass: no worktree, only `gh` commands, no file access and none of your MCP servers. The result is cached per head commit, so asking again is free until someone pushes. Summaries run on their own pool (five at once by default) and never start a review.

## Privacy and trust

- **Local-only.** Reviews, findings, summaries and the Jira cache live in `~/Library/Application Support/Foreword/`; clones and worktrees in `~/.foreword/`. Nothing is written back to GitHub or Jira.
- **What leaves your machine.** GitHub API calls go to GitHub, Jira calls to your Jira site. During a review, `claude` sends the PR diff, the files it reads and the Jira ticket text to Anthropic, exactly as if you'd run Claude Code on the branch yourself.
- **Credentials.** The GitHub token and Jira credentials are kept in the macOS Keychain.
- **Environment.** Processes Foreword starts don't inherit your shell environment wholesale:
  - IntelliJ gets a filtered copy of your login shell's environment: `PATH`, `JAVA_*`, `GRADLE_*`, `MAVEN_*`, locale and SSH agent variables. Anything else, such as `ANTHROPIC_API_KEY` or AWS credentials, is dropped unless you list it under Settings → Behavior → "Forward extra environment variables" (for example private Maven repository credentials that IntelliJ's Gradle import needs).
  - `claude` gets `HOME`, `USER`, `TERM`, `LANG`, a `PATH` built from the tool locations, and any `ANTHROPIC_*` / `CLAUDE_*` variables present in Foreword's own environment. When you launch the app from Finder or the Dock that is usually none, so `claude` uses its own sign-in.
  - `git` and `gh` get only `HOME`, `USER` and a fixed `PATH`.
- **Binaries.** `git`, `gh`, `claude` and `idea` are looked up in the usual system locations plus `/usr/local/bin` and `/opt/homebrew/bin`, and Foreword runs whichever it finds first. That's the same trust you give your terminal's `PATH`. If you don't trust everything that can write to those directories, pin each tool to a fixed path in Settings → Tools.

See [SECURITY.md](SECURITY.md) for the threat model and how to report a vulnerability.

## The legacy HTML dashboard

The repo also contains the dashboard Foreword grew out of: `index.html`, a single file you open in a browser. It has Reviews and My PRs tabs, no build step and no server, and none of the review features. You don't need it to run the app. It stays in the repo because it still works and costs nothing to keep; new features go into the app only.

```sh
open index.html
gh auth token | pbcopy   # paste into the token prompt; stored in the page's localStorage
```

## Development

```sh
make build
xcodebuild test -project Foreword/Foreword.xcodeproj -scheme Foreword \
  -destination 'platform=macOS' -only-testing:ForewordTests
```

See [CONTRIBUTING.md](CONTRIBUTING.md). Domain terms are in [CONTEXT.md](CONTEXT.md), architecture decisions in [docs/adr/](docs/adr/), and the slice-by-slice build history in [docs/issues/](docs/issues/).

## License

MIT, see [LICENSE](LICENSE). The bundled fonts, Libre Baskerville and Source Sans 3, are under the SIL Open Font License 1.1, see [OFL.txt](Foreword/Foreword/Resources/Fonts/OFL.txt).
