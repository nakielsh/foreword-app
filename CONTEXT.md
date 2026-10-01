# Context

Domain glossary for WorkHomepage. Terms here are meaningful to me as the user — not implementation details. See `docs/PRD.md` for the broader product story and `docs/adr/` for decisions.

## Pull Request (PR)

A GitHub pull request. Surfaces in three tabs (Reviews, My PRs, Deployments-adjacent). The same PR object may show up in different tabs with different framing (waiting on me to review vs. authored by me).

## Review

A Claude-driven analysis of one specific `(repo, prNumber, headSha)`. Versioned per `headSha`: a new commit produces a new Review row, never an in-place update. Findings, verdict, summary, and Jira-alignment notes are all attached to one Review.

A Review is *not* the same as a GitHub review. Reviews stay local — never posted to GitHub.

## Pre-Review Summary

A lightweight Claude pass that produces a 3-bullet TL;DR (`what / why / risk`) for one `(repo, prNumber, headSha)`. Distinct from a full Review:

- **Pre-Review Summary** — runs without a worktree, uses `Bash(gh:*)` only, on its own concurrency pool, manually triggered per card. Cached forever per `headSha`. Cheap (~10s, one Claude call).
- **Review** — runs in an isolated worktree with full tools, on the main concurrency pool, manually triggered per card. Versioned per `headSha`. Expensive (~30s+, multiple Claude turns).

The summary is decision support for *whether* to review. It does not replace, gate, or seed the Review.

## Review Prompt Template

The user-editable string in `AppSettings` that becomes the PR-body block of every Review's prompt (after the auto-rendered Jira block, before the auto-appended schema directive). Supports `{{repo}}`, `{{prNumber}}`, `{{branch}}`, `{{sha}}` placeholders. Single global value — not per-repo, not per-run.

## Reviewer

A GitHub user listed in a PR's `requestedReviewers` or `latestReviews`. Distinct from a PR's **Author** (the user who opened it). Both render in the UI with avatar + login + tooltip; their roles are surfaced explicitly in the tooltip text.

## Jira Ticket

An Atlassian Cloud issue extracted from a branch name (`feature/PROJ-123` → `PROJ-123`). Optionally has a **Parent Ticket** when the matched issue is a subtask with a thin description. Both ticket and parent are sent to Claude as part of the Review prompt's Jira block.

A ticket is "found" if and only if `TicketKeyExtractor.extract(branchName:)` returns a key AND `JiraClient.fetchTicket` succeeds (cached or live). When found, a pill badge `[KEY]` renders on the PR card and links to `<jira.baseURL>/browse/<KEY>`. When not found, no badge.

## Worktree

An isolated git working directory at `~/.work-homepage/worktrees/<org>/<repo>/<pr#>/`, backed by a bare clone at `~/.work-homepage/repos/<org>/<repo>.git`. One worktree per PR. Created lazily on first Review, refreshed on re-review, evicted when the PR closes/merges or manually.

## Theme

The visual identity shared between the original HTML dashboard and the macOS app — Botanical Garden palette (cream `#f5f3ed`, fern green `#4a7c59`, marigold, terracotta), Libre Baskerville (display, serif) + Source Sans 3 (body, sans). Tokens live in the asset catalog with hand-picked dark variants for two anchor colors (background + primary text); other tokens auto-flip via HSL inversion.
