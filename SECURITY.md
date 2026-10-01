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

`gh` runs with your GitHub credentials, so an injected `gh` command could act as you on GitHub (for example comment on a PR). The default prompt never asks for write operations and the app never posts anything itself; review the [allow-list](Foreword/Foreword/Services/ReviewOrchestrator.swift) if this matters for your setup.

### Untrusted content in the prompt

Branch names and Jira summaries / descriptions (ticket and parent) are wrapped in labelled untrusted-content fences (`UntrustedContent` in `ReviewOrchestrator.swift`) before they reach the prompt, so the model can see where data ends and instructions begin. The text itself isn't filtered. This is defence in depth on top of the tool restrictions, not a guarantee.

### Findings

Claude's JSON output is decoded against a fixed schema. Findings whose `file` is empty, absolute, or doesn't exist in the worktree are dropped before anything is stored or shown. Clicking a finding only opens that file in your editor; nothing is executed.

### Secrets

- The GitHub token and Jira credentials are stored in the macOS Keychain, never in files or UserDefaults.
- Child processes (`claude`, `git`, `gh`, IntelliJ) get an allow-listed subset of your shell environment. Tokens such as `ANTHROPIC_API_KEY` or AWS credentials are dropped unless you explicitly add them in Settings.
- `gh auth token` is only read when you ask for it in the setup sheet.

### Binaries

Foreword runs the first `git`, `gh`, `claude` and `idea` it finds in the system locations plus `/usr/local/bin` and `/opt/homebrew/bin`. Anything that can write to those directories can substitute a binary. Pin tools to fixed paths in Settings → Tools if that's a concern.

### Not sandboxed

The app is not App Sandboxed: it has to start `git`, `gh` and `claude` and read `~/.claude/`. It runs with your user's permissions.
