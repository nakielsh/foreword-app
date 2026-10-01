# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue for anything that could be exploited. You should get a reply within a week.

## Threat model

Foreword runs Claude Code against pull requests written by other people. A PR diff, its branch name and the linked Jira ticket are all **untrusted input**, and a hostile PR can try to talk the model into doing something other than reviewing. The app is built so that a successful prompt injection can't do much.

### What `claude` is allowed to do

Reviews run `claude` with its working directory set to a throwaway git worktree of the PR head:

- **Allowed tools:** `Read`, `Grep`, `Glob`, `Skill`, `Bash(gh:*)`, `Bash(git:*)`.
- **Denied tools:** `Bash` (anything other than `gh` / `git`), `Write`, `Edit`, `Task`, `TodoWrite`, `WebFetch`, `WebSearch`.

The pre-review summary is narrower still: only `Bash(gh:*)`, no file access, no MCP servers.

A review is killed after the configured timeout (30 minutes by default, Settings → Behavior), a summary after 3 minutes.

`gh` runs with your GitHub credentials, so an injected `gh` command could act as you on GitHub (for example comment on a PR). The default prompt never asks for write operations and the app never posts anything itself; review the [allow-list](Foreword/Foreword/Services/ReviewOrchestrator.swift) if this matters for your setup.

### Untrusted content in the prompt

Branch names and Jira summaries / descriptions (ticket and parent) are wrapped in labelled untrusted-content fences (`UntrustedContent` in `ReviewOrchestrator.swift`) before they reach the prompt, so the model can see where data ends and instructions begin. The text itself isn't filtered. This is defence in depth on top of the tool restrictions, not a guarantee.

### Repo and branch names

Before any clone or worktree operation, the repo identifier must match `<owner>/<repo>` with `[A-Za-z0-9._-]` on each side, and the branch name is rejected if it is empty, starts with `-`, contains `..`, control characters, whitespace, or any of `: ? [ \ ^ ~ *`. This keeps a hostile branch name from turning into a git option or an unexpected ref.

### Findings

Claude's JSON output is decoded against a fixed schema. Findings whose `file` is empty, absolute, or doesn't exist in the worktree are dropped before anything is stored or shown. Clicking a finding only opens that file in your editor; nothing is executed.

### Secrets

- The GitHub token and Jira credentials are stored in the macOS Keychain, never in files or UserDefaults.
- Child processes never inherit your shell environment wholesale:
  - IntelliJ gets an allow-listed subset of your login shell's environment (`PATH`, `JAVA_*`, `GRADLE_*`, `MAVEN_*`, locale, SSH agent). Tokens such as `ANTHROPIC_API_KEY` or AWS credentials are dropped unless you explicitly add them in Settings → Behavior.
  - `claude` gets `HOME`, `USER`, `TERM`, `LANG`, a constructed `PATH`, and any `ANTHROPIC_*` / `CLAUDE_*` variables in Foreword's own process environment. Launched from Finder or the Dock, that environment comes from launchd and normally has none; if you set them with `launchctl setenv` or start the binary from a terminal, they are passed through.
  - `git` and `gh` get `HOME`, `USER` and a fixed `PATH`.
- `gh auth token` is only read when you ask for it in the setup sheet.

### Binaries

Foreword runs the first `git`, `gh`, `claude` and `idea` it finds in the system locations plus `/usr/local/bin` and `/opt/homebrew/bin`. Anything that can write to those directories can substitute a binary. Pin tools to fixed paths in Settings → Tools if that's a concern.

### Not sandboxed

The app is not App Sandboxed: it has to start `git`, `gh` and `claude` and read `~/.claude/`. It runs with your user's permissions.
