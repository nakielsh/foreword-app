# 04 — Claude Code Sessions tab parity

## What to build

Port the Claude Code tab to SwiftUI, replacing the Python helper script + launchd agent + `claude-sessions.js` mechanism with an on-demand native reader.

Behavior:

- A `SessionsReader` service is added with public surface `currentSessions() -> [Session]`.
- It reads `~/.claude/sessions/*.json`, validates each `pid` is alive via `Darwin.kill(pid, 0)`, drops dead entries.
- It tails `~/.claude/history.jsonl`, groups the last user prompt per session `cwd`, truncates each to 200 chars.
- Sessions are sorted newest-first by start time.
- The Sessions tab renders cards showing entrypoint (CLI vs VS Code), running duration, cwd (with `/Users/<username>` replaced by `~`, prefix dimmed), session name or last prompt, PID, start time.
- Reader runs only when the user clicks the global refresh button on the Sessions tab. No FSEvents, no polling, no background work.

This slice does NOT yet delete the old Python script + plist template — that happens in slice 18 after all parity tabs are confirmed working.

## Acceptance criteria

- [ ] Refresh button on Sessions tab triggers a fresh read; old data not auto-refreshed.
- [ ] Dead PIDs are filtered out.
- [ ] cwd display abbreviates `/Users/<username>` → `~` with dimmed prefix.
- [ ] Last prompt per session is truncated at 200 chars.
- [ ] Sessions sorted newest-first.
- [ ] Empty state when no sessions.
- [ ] Behavior matches what `refresh-sessions.py` produces today.

## Blocked by

- Issue 01 (App skeleton + Reviews tab MVP)
