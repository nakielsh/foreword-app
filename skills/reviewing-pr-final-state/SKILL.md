---
name: reviewing-pr-final-state
description: Review pull requests against the cumulative final state — same view as GitHub's "Files changed" tab. Resolves the PR's actual base branch (feature→main, feature→feature, or otherwise) and diffs three-dot from that base, never from main by default and never per-commit. Use when reviewing a PR in a worktree checked out at the PR head SHA, when scoping which files belong to a PR, when the user mentions reviewing a PR or "Files changed", or when a spawned review agent needs to bound its inspection to PR contributions.
---

# Reviewing PR Final State

## Core rule

The PR you are reviewing is the **end state** of all its commits combined — exactly what GitHub's *Files changed* tab shows. Never review intermediate commits. Never read a prior version of a file changed by this PR. A method rewritten across three commits is one method: the final one.

## Step 0 — resolve the base branch

**Do this first. Never assume the base is `main`.** A PR can target any branch: most target `main`, but stacked-feature PRs target another feature branch.

```bash
BASE=$(gh pr view <N> --repo <O/R> --json baseRefName --jq .baseRefName)
HEAD_REF=$(gh pr view <N> --repo <O/R> --json headRefName --jq .headRefName)
```

Then classify:

- `BASE == main` (or `master`, `develop` — the repo's trunk): **feature → trunk**. Standard PR. Diff scope is this PR's contributions to trunk.
- `BASE` is itself a feature branch: **feature → feature** (stacked PR). Diff scope is only what this PR adds **on top of the parent feature branch**. The parent's own changes are NOT part of this review — they belong to the parent's PR.

Call out the case in your review. For stacked PRs, surface: "Stacked on `<BASE>` — review scope excludes parent's changes." Do not flag findings that live in the parent feature branch.

## Quick start

```bash
# After Step 0 — every command below uses $BASE, not a hard-coded "main".

# File set (authoritative — exactly what GitHub's "Files changed" lists)
gh pr diff <N> --repo <O/R> --name-only

# Full unified diff
gh pr diff <N> --repo <O/R>

# Equivalent local form (use when gh is unavailable)
git diff origin/$BASE...HEAD --name-only   # three dots — merge-base diff
git diff origin/$BASE...HEAD
```

## Forbidden

- `git show <sha>` — surfaces a dead intermediate snapshot.
- `git log -p` — per-commit patches, not cumulative.
- `git diff HEAD~N` — wrong base; depends on commit count.
- `git diff origin/<base>..HEAD` (two dots) — includes commits added to base since branching, polluting the diff. **Two dots vs three dots matters.**
- `git diff origin/main...HEAD` when `BASE != main` — diffs against the wrong base; pulls in the parent feature branch's changes as if they were yours.
- Reading prior versions of any file changed by this PR (via `git show <sha>:path`, `git checkout <sha> -- path`, or reflog). The worktree at HEAD is the only version under review.
- Treating worktree filesystem existence as PR membership. The worktree contains the entire repo at HEAD; most files were already on the base and are NOT part of this PR.

## Allowed for context

- `git log --oneline origin/$BASE..HEAD` — commit messages on this PR, no patches.
- `git blame <file>` — authorship/timeline on a single file's current state.
- `Read`, `Grep`, `Glob` on the worktree — final state of any file.
- `gh pr view <N> --repo <O/R>` — PR body, labels, reviewers, base/head refs.

## Workflow

1. **Resolve base** (Step 0). Capture `BASE` and `HEAD_REF`. Classify feature→trunk vs feature→feature.
2. **Fetch file set**: `gh pr diff <N> --name-only`. Hold this list — it bounds every finding.
3. **Read the diff**: `gh pr diff <N>`. This is the unit of review.
4. For each interesting file, `Read` the **current** worktree contents for surrounding context. Do not look up prior versions.
5. Cross-check with `git log --oneline origin/$BASE..HEAD` only for commit-message intent.
6. Every finding's file path must come verbatim from step 2's list. Do not invent siblings, do not normalise.
7. If stacked, note the parent in the review summary. Do not flag findings against parent-only code.

## Why three dots

- `A..B` = commits in B not in A. If `BASE` advanced after the PR branched, `BASE..HEAD` mixes new-on-base commits into the diff.
- `A...B` = symmetric difference from the merge-base. This is the diff GitHub shows. Always three dots for PR review.

## Output format

The host passes a JSON Schema via `--json-schema`, but the CLI treats it as guidance, not enforcement. Two runs against the same PR can return different shapes, which breaks downstream rendering. Pin the field names yourself.

Top level:

```json
{
  "summary": "...",
  "verdict": "approve" | "request_changes" | "comment",
  "findings": [ ... ],
  "jira_alignment": { "matches_ticket": true|false|null, "notes": "..." } | null
}
```

Each finding:

```json
{
  "severity": "blocker" | "major" | "minor" | "nit" | "praise",
  "file": "<verbatim path from allowlist>",
  "line": <1-based integer>,
  "endLine": <integer or omitted>,
  "title": "<one-line headline>",
  "message": "<1-3 sentence explanation>",
  "suggestion": "<optional code-level fix or null>"
}
```

Rules:

- Use **exactly** these field names. Do not substitute `issue` for `title`, `description`/`explanation` for `message`, `suggestedFix` for `suggestion`, or `overallVerdict` for `verdict`.
- Severity must be one of the five enum values above. Do not emit `suggestion`, `nitpick`, `critical`, `high`, `medium`, `low`, or `info` as severity.
- Do not add extra top-level keys (`qualityScore`, `assessments`, `securityConcerns`, `ticketAlignment`, etc.). Put any such commentary in `summary`.
- Do not add extra per-finding keys (`category`, `effortToFix`, `impact`, etc.). Roll any such detail into `message`.

## When to invoke

- A spawned `claude` review agent starts in a worktree at the PR head SHA.
- User asks "review PR #N" or mentions GitHub's *Files changed* view.
- Task description references reviewing a PR, code review, or scoping a diff to its base.
- Stacked / dependent PR work where the base is itself a feature branch.
