# 18 — Cleanup: delete HTML + python + launchd, rewrite README + CLAUDE.md

## What to build

Final-phase cleanup. Remove the legacy browser dashboard and helper scripts now that the SwiftUI app is at parity and shipping new features.

Files to delete:

- `index.html`
- `claude-sessions.js`
- `refresh-sessions.py`
- `refresh-sessions.sh`
- `refresh-claude-sessions.plist.template`

Files to update:

- `README.md` — replace HTML/launchd instructions with:
  - Xcode build instructions (clone, open `WorkHomepage.xcodeproj`, build & run).
  - First-run wizard description (matches slice 06).
  - Mention that the LaunchAgent setup is no longer needed.
  - Optional one-liner for users still running the LaunchAgent: `launchctl unload ~/Library/LaunchAgents/com.work-homepage.refresh-claude-sessions.plist && rm ~/Library/LaunchAgents/com.work-homepage.refresh-claude-sessions.plist` to clean up.
- `CLAUDE.md` — rewrite from scratch for the SwiftUI structure:
  - Project overview points at the app, not `index.html`.
  - Architecture section describes the modules from the PRD (`WorktreeManager`, `ClaudeRunner`, `GitHubClient`, etc.).
  - Key patterns section covers SwiftData models, Keychain entries, binary resolution, manual-refresh model.
  - Mentions that the legacy HTML dashboard is preserved in git history (tag `legacy-html` if user wants — see acceptance criteria).
- `.gitignore` — add `.build/`, `xcuserdata/`, `*.xcuserstate`, etc., if not already present and the project is git-init'd.

This is HITL: confirm with user before deletion. Once confirmed, the actual deletions and rewrites are mechanical.

## Acceptance criteria

- [ ] User confirms before any file is deleted.
- [ ] All legacy files listed above are removed from the working tree.
- [ ] `README.md` matches the new SwiftUI workflow with no references to `index.html` or `refresh-sessions.*`.
- [ ] `CLAUDE.md` matches the new architecture; no stale references to HTML/launchd.
- [ ] If user opts in, a `legacy-html` git tag (or a branch `archive/legacy-html`) is created on the last commit before deletion, so the old dashboard remains recoverable.
- [ ] Building from a fresh clone using only the new README produces a working app.

## Blocked by

- Issue 02 (Reviews tab full parity)
- Issue 03 (My PRs tab parity)
- Issue 04 (Sessions tab parity)
- Issue 05 (Deployments tab parity)
