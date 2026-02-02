# 06 — BinaryResolver + first-run wizard

## What to build

A `BinaryResolver` service plus a first-run wizard that walks the user through one-time setup.

GUI macOS apps launched from Finder do not inherit shell `PATH`. Every binary the app spawns (`claude`, `gh`, `git`, `idea`) must be resolved to an absolute path at startup and persisted in `UserDefaults`. Spawning via `/bin/zsh -lc "..."` is forbidden in this app — slow, fragile, swallows env oddities. Use `Process.executableURL` with absolute paths only.

`BinaryResolver` public surface:

- `resolve(.claude | .gh | .git | .idea) -> URL?` — returns the persisted absolute path.
- `validate(allTools) -> [Tool: Status]` — re-probes and reports `found(URL)` or `missing` per tool.
- `setOverride(tool, URL)` — persist a manual override.

Probe candidates (in order): `/opt/homebrew/bin`, `/usr/local/bin`, `~/.claude/local`, `/Applications/IntelliJ IDEA.app/Contents/MacOS`. For `idea` specifically, also probe the JetBrains Toolbox shim path.

First-run wizard (single sheet, skippable per section, re-openable from Settings):

1. GitHub token — auto-fill from `gh auth token` if `gh` resolved, else paste box.
2. Jira config — base URL, email, API token (testable via "Test Connection" button — but the actual JiraClient ships in slice 10; for slice 06 the wizard just persists strings to Keychain).
3. Tool paths — show resolved paths for `claude` / `gh` / `git` / `idea` with green/red dots and "Browse..." overrides.
4. Project key prefixes — text field, default empty (= accept any `[A-Z]+-\d+`).
5. Concurrency cap — number stepper, default 3, range 1–10.

Settings view exposes the same controls plus a "Re-detect" button that re-runs `validate(allTools)`.

## Acceptance criteria

- [ ] First launch presents the wizard sheet.
- [ ] Wizard skippable per section; later re-openable from Settings.
- [ ] Tool paths auto-detect on the typical macOS dev machine; user can override via "Browse...".
- [ ] Settings shows green/red status dots that update on "Re-detect".
- [ ] All persisted values (paths, prefixes, concurrency cap, Jira URL/email/token) survive app restart.
- [ ] Tokens land in Keychain; non-secret values land in `UserDefaults`.
- [ ] No code path uses `/bin/zsh -lc` or relies on PATH; all binary launches resolve via `BinaryResolver`.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
