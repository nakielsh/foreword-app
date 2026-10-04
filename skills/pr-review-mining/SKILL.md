---
name: pr-review-mining
description: Mine GitHub PR review comments to extract recurring code-review feedback, verify findings against the current codebase, and append the result as a clearly-marked section in CLAUDE.md. Use when the user asks to "analyze PR review comments", "find common review feedback", "extract code standards from reviews", "what mistakes do we make in PRs", or "add review findings to CLAUDE.md".
---

# PR Review Mining

Extracts team conventions and recurring mistakes from GitHub PR review history, verifies them against the current codebase, and writes them to `CLAUDE.md` as a self-labelled section.

## Inputs to clarify before running

1. **Timeframe** — default 6 months. User may say 1m / 3m / 6m / 1y.
2. **Reviewer scope** — default `--reviewed-by=$current_gh_user`. Alt: `--review-requested=<user>`, `--involves=<user>`, or all PRs in repo.
3. **Repo** — default `gh repo view --json nameWithOwner --jq .nameWithOwner` from cwd.
4. **CLAUDE.md target** — repo root by default; ask if multiple `CLAUDE.md` files exist.

If any of these is ambiguous, ask once before running.

## Workflow

### 1. Fetch PR list

```bash
GH_USER=$(gh api user --jq .login)
REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
SINCE=$(date -v-6m +%Y-%m-%d)   # macOS; linux: date -d '6 months ago' +%Y-%m-%d

# open + closed must be queried separately; --state=all is rejected
gh search prs --repo "$REPO" --reviewed-by="$GH_USER" --updated=">=$SINCE" --limit 200 --state=open   --json number,title,author,state,createdAt
gh search prs --repo "$REPO" --reviewed-by="$GH_USER" --updated=">=$SINCE" --limit 200 --state=closed --json number,title,author,state,createdAt
```

Exclude PRs authored by `$GH_USER` — reviewer perspective only.

`scripts/fetch_pr_comments.sh` automates steps 1–2: pass `<timeframe>` (e.g. `6m`, `1y`) and an optional reviewer; writes JSON streams to `/tmp/pr_review_<tag>/`.

### 2. Fetch all comment streams per PR

For every PR number, pull three streams (any may be empty):

```bash
# inline review comments (file + line)
gh api "repos/$REPO/pulls/$PR/comments" --paginate \
  --jq '.[] | {pr: '"$PR"', user: .user.login, path: .path, line: (.line // .original_line), body: .body, created: .created_at}'

# review summary bodies (CHANGES_REQUESTED / APPROVED / COMMENTED)
gh api "repos/$REPO/pulls/$PR/reviews" \
  --jq '.[] | select(.body != "") | {pr: '"$PR"', user: .user.login, state: .state, body: .body}'

# top-level PR conversation (issue comments)
gh api "repos/$REPO/issues/$PR/comments" \
  --jq '.[] | {pr: '"$PR"', user: .user.login, body: .body, created: .created_at}'
```

Persist to `/tmp/pr_review_<timeframe>/pr_<num>.json` for inspection.

### 3. Cluster comments into themes

Read the corpus and group by theme. Common buckets:

- **Naming / consistency** — prefixes, suffixes, factory usage, ID placement.
- **Package / file organisation** — flat vs nested, where DTOs/exceptions/configs live.
- **Configuration** — defaults, env split, properties vs DTOs.
- **Language idioms** — annotation targeting, visibility, deprecated APIs.
- **Error handling** — exception type vs class-name match, retry scope, graceful degrade.
- **Testing** — assertion library, pattern mirroring, client lifecycle, prod-parity config.
- **Domain / API design** — DTO shape, body vs query, param forwarding.
- **Comments / docs** — JavaDoc policy, comment-when-why-non-obvious.
- **Process** — commit messages, PR titles, ticket coverage.

For each theme: list the recurring rule + representative quote(s) + PR refs. Drop one-offs unless they signal a pattern.

### 4. Verify against current codebase

Findings are claims that may be outdated (PR landed, was reverted, never merged, or merged differently). Spawn parallel `Explore` subagents — one per theme cluster — to verify:

- File / class / package mentioned **exists** at the path implied.
- Pattern is actually applied (grep for usage; count violations).
- Note any **gaps** — comments said "do X" but code shows X is partly applied / inconsistent / inverted.

The verification step rewrites the doc. Example: a comment said "Redis-down should gracefully degrade" but the merged code does **wait+retry+timeout** instead — the CLAUDE.md must reflect `main`, not the conversation. Quote `file:line` from the codebase, not from the review thread.

### 5. Write the CLAUDE.md section

Append (or create) a clearly-labelled, replaceable block:

```markdown
<!-- pr-review-mining:begin -->
## Project conventions (from PR review feedback)

_Generated from PR reviews on <REPO> over the last <TIMEFRAME>. Last refreshed: <YYYY-MM-DD>. Sources: PRs #<list>._

### <Theme>
- <rule> — <file:line>. <quote/justification if non-obvious>.

### <Theme>
- ...

### Reviewer hot-spots (where mistakes recur)
1. ...
<!-- pr-review-mining:end -->
```

Rules for the section:

- **Wrap with HTML markers** `<!-- pr-review-mining:begin -->` / `<!-- pr-review-mining:end -->` so a refresh can replace exactly that block without disturbing the rest of `CLAUDE.md`.
- **Verified findings only** — every rule references a real file path or is flagged as a known gap.
- **Cite PR numbers** in the header so the user can audit.
- **Imperative voice** — "Use AssertJ", not "AssertJ is preferred".
- **Match project's own writing style** — no JavaDoc / no fluff if that's the team norm.
- **Avoid markdown lint traps** — code fences inside list items often trigger "Expecting an element". Prefer inline code or place fences at root level.

If `CLAUDE.md` already has a `pr-review-mining` block, replace it. If `CLAUDE.md` doesn't exist, create it with this block as the first section.

## Common pitfalls

- **`gh search prs --state=all` is rejected** — call `--state=open` and `--state=closed` separately.
- **Author == reviewer** — `--reviewed-by=$user` returns PRs the user authored if they self-reviewed. Filter those out.
- **Empty comment streams** — many merged PRs have zero review comments. Don't error; skip.
- **`@param:` vs `@field:`** — when a comment says "use `@param:`", verify the target. Constructor params need `@param:`; field-level `@Value` properties don't.
- **Review intent ≠ merged code** — what the reviewer asked for and what was merged can diverge. The CLAUDE.md must reflect `main`, not the conversation.
- **Don't include user-authored PRs** — they bias toward the user's own style, not team consensus.
- **Filter bots** — drop `dependabot`, `renovate`, `github-actions`, etc.
- **Review-summary bodies often duplicate inline comments** — dedupe on `(pr, user, body[:80])` before clustering.
- **Threaded replies look like new comments** — comments quoting `>` lines are usually replies; weight by the original parent.
