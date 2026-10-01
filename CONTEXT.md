# Context

Domain glossary for Foreword. Terms here are meaningful to me as the user — not implementation details. See `docs/PRD.md` for the broader product story and `docs/adr/` for decisions.

## Pull Request (PR)

A GitHub pull request. Surfaces in two tabs (Reviews, My PRs). The same PR object may show up in different tabs with different framing (waiting on me to review vs. authored by me).

## Review

A Claude-driven analysis of one specific `(repo, prNumber, headSha)`. Versioned per `headSha`: a new commit produces a new Review row, never an in-place update; earlier versions stay browsable as history. Findings, verdict, summary, and Jira-alignment notes are all attached to one Review. All Reviews for a PR (with their Findings) are dropped once the PR closes or merges.

A Review is *not* the same as a GitHub review. Reviews stay local — never posted to GitHub.

## Pre-Review Summary

A lightweight Claude pass that produces a 2–4 sentence plain-prose TL;DR covering what changed, why, and what is risky, for one `(repo, prNumber, headSha)`. Distinct from a full Review:

- **Pre-Review Summary** — runs without a worktree, uses `Bash(gh:*)` only, on its own concurrency pool, manually triggered per card. Cached forever per `headSha`. Cheap (~10s, one Claude call).
- **Review** — runs in an isolated Worktree with the read-only tool set (`Read`, `Grep`, `Glob`, `Skill`, `gh`, `git`), on the main concurrency pool, manually triggered per card. Versioned per `headSha`. Expensive (~30s+, multiple Claude turns).

The summary is decision support for *whether* to review. It does not replace, gate, or seed the Review.

## Review Prompt Template

The user-editable string in `AppSettings` that becomes the PR-body block of every Review's prompt (after the auto-rendered Jira block, before the auto-appended schema directive). Supports `{{repo}}`, `{{prNumber}}`, `{{branch}}`, `{{sha}}` placeholders. Single global value — not per-repo, not per-run.

## Reviewer

A GitHub user listed in a PR's `requestedReviewers` or `latestReviews`. Distinct from a PR's **Author** (the user who opened it). Both render in the UI with avatar + login + tooltip; their roles are surfaced explicitly in the tooltip text.

## Jira Ticket

An Atlassian Cloud issue extracted from a branch name (`feature/PROJ-123` → `PROJ-123`; for configured project keys also `PROJ-123-fix`, `jane/PROJ-123`). Optionally has a **Parent Ticket** when the matched issue is a subtask with a thin description. Both ticket and parent are sent to Claude as part of the Review prompt's Jira block.

A **Jira badge** renders on a PR card (and in the Review window header) when `TicketKeyExtractor.extract(branchName:projectKeyPrefixes:)` returns a key AND a Jira base URL is configured. It links to `<jira.baseURL>/browse/<KEY>` and reads `KEY · Status` once `JiraClient.fetchTicket` succeeds (cached or live); if the fetch fails it stays a key-only link. No key or no base URL → no badge.

## Worktree

An isolated git working directory at `~/.foreword/worktrees/<org>/<repo>/<pr#>/`. Backed by the user's own clone when one is found under the Local Repos search roots (default `~/src`), otherwise by a bare clone at `~/.foreword/repos/<org>/<repo>.git`. One worktree per PR. Created lazily on first Review, refreshed on re-review, evicted when the PR closes/merges or manually. Evicting never deletes the backing clone.

## Theme

The visual identity shared between the macOS app and the legacy HTML dashboard — Botanical Garden palette (cream `#f5f3ed`, fern green `#4a7c59`, marigold, terracotta), Libre Baskerville (display, serif) + Source Sans 3 (body, sans), bundled with the app. Tokens live in the asset catalog with hand-picked dark variants for the background, primary text and card colors; other tokens are HSL inversions (ADR-0001).
