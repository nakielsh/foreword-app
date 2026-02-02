# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A single-page HTML dashboard for developer productivity. It displays GitHub PR data (reviews, authored PRs, deployments) and active Claude Code sessions. Runs as a local `file://` page — no build step, no framework, no dependencies.

## Architecture

**`index.html`** — The entire app: HTML, CSS (in `<style>`), and JS (in `<script>`). Uses the Botanical Garden theme (Libre Baskerville + Source Sans 3 fonts, fern green/marigold/terracotta/cream palette).

Four tabs:

- **Reviews** — PRs assigned to the user for review (`review-requested:@me`).
  - Filter bar: "Hide PRs with >= N approvals" dropdown (threshold 1–5, default 2) and "Show my dismissed reviews" toggle.
  - Stats bar: counts for awaiting / with approvals / drafts / dismissed / currently showing.
  - Main grid of pending review-requested PRs.
  - Three sub-sections for PRs from `reviewed-by:@me` that are no longer pending review:
    - **Changes Requested** — your last review was CHANGES_REQUESTED.
    - **My Comments** — your last review was COMMENTED.
    - **Already Approved** — your last review was APPROVED.
  - Each reviewed PR shows a "N new commits since your review" badge when commits were pushed after your last review, and a re-review indicator showing your prior review state.

- **My PRs** — User's authored open PRs (`author:@me+is:pr+is:open`).
  - Per-reviewer status badges (approved / changes requested / commented / pending / re-requested).
  - Unresolved thread counts via GitHub GraphQL API, split into "awaiting you" vs "awaiting others".
  - Total comment counts.
  - Stats bar: with approvals / changes requested / awaiting your reply / drafts / total.

- **Claude Code** — Active Claude Code sessions read from `claude-sessions.js` (`window.__claudeSessions`).
  - Cards show entrypoint (CLI vs VS Code), running duration, cwd, session name or last prompt, PID, and start time.
  - File is reloaded dynamically with cache-busting via `reloadSessionsScript()`.

- **Deployments** — Deployment status per service for the `Ala-com` GitHub org.
  - Queries GitHub Actions workflow runs for each service in the hardcoded `SERVICES` array, looking for the workflow named in `DEPLOY_WORKFLOW`.
  - `parseDeployRun(run)` extracts environment (prod/dev) and version from run names (e.g., `[dev] Deploy v1.21.1-feature-xyz-snapshot`).
  - `fetchDeployEnvMap()` pages through up to 200 runs to avoid prod info being buried by frequent dev deploys.
  - Uses progressive rendering: skeleton cards appear immediately, each fills as its API call resolves.
  - Org/workflow/services are configured near `index.html:1764` via `DEPLOY_ORG`, `DEPLOY_WORKFLOW`, and `SERVICES`.

Data sources:
- GitHub REST API (`api.github.com`) for PR search, reviews, and workflow runs.
- GitHub GraphQL API for review threads and requested reviewers (My PRs tab only).
- Token stored in `localStorage`, obtained via `gh auth token`.
- Filter state and active tab persisted in `localStorage`.

**`refresh-sessions.py`** — Reads `~/.claude/sessions/*.json`, validates PIDs are alive via `os.kill(pid, 0)`, pulls the last user prompt per session from `~/.claude/history.jsonl` (truncated to 200 chars), and writes `claude-sessions.js` next to itself. Output is `window.__claudeSessions = [...]` sorted newest-first.

**`refresh-sessions.sh`** — Portable shell wrapper that resolves its own directory and invokes `refresh-sessions.py` via `/usr/bin/python3`. Used by launchd. No hardcoded paths — colleagues can run it from any working directory.

**`refresh-claude-sessions.plist.template`** — Template LaunchAgent plist. Replace the `__INSTALL_DIR__` placeholder with the absolute path to this project directory, copy to `~/Library/LaunchAgents/`, and load with `launchctl load`. See README.md for the one-liner setup command.

**LaunchAgent** — Runs `refresh-sessions.sh` every 120 seconds and once on login (`RunAtLoad true`). Stdout and stderr both go to `/tmp/refresh-claude-sessions.log`. No `WorkingDirectory` is set; the script uses absolute paths derived at runtime.

## Key Patterns

- All CSS uses custom properties defined in `:root`. Theme changes only require updating variables and hardcoded `rgba()` values.
- Card rendering is done via DOM creation in JS (no templating library). `renderReviewCards(grid, prs)` is shared between the pending reviews section and all three sub-sections (Changes Requested, My Comments, Already Approved).
- GitHub API calls go through `ghFetch()` (REST) and `ghGraphQL()` (GraphQL), both handling 401 → token clear.
- `formatCwd(cwd)` replaces `/Users/<username>` with `~` for display and dims the path prefix.
- `reloadSessionsScript()` replaces the `<script>` tag for `claude-sessions.js` with a cache-busting query param, returning a Promise. Works with `file://` protocol.
- `fetchDeployEnvMap(service)` pages through up to 2 pages of 100 workflow runs to find the latest deploy per environment, avoiding the problem where frequent dev deploys push prod off the first page.
- `parseDeployRun(run)` parses workflow run names via regex to extract environment and version.
