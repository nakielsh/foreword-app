# 07 — Tracer bullet: end-to-end review on a real PR

## What to build

The first complete vertical that proves the whole review pipeline works on a real PR. Intentionally minimal: no Jira, no styled findings, no IntelliJ launcher, no concurrency cap, no versioning. All those features pile on in later slices.

Behavior:

- Each PR card in the Reviews tab gets a **Review** button.
- Clicking it opens a modal sheet and triggers the orchestrator:
  1. `WorktreeManager.prepare(repo, branch, sha)` — first time per repo, do `git clone --bare git@github.com:<org>/<repo>.git ~/.work-homepage/repos/<org>/<repo>.git` (HTTPS fallback if no `~/.ssh/id_*`). Then `git worktree add ~/.work-homepage/worktrees/<org>/<repo>/<pr#> origin/<branch>` from the bare repo. Surface clone progress in the modal.
  2. `ClaudeRunner.run(prompt, schema, cwd, allowedTools, timeout)` spawns `claude -p <prompt> --output-format stream-json --include-partial-messages --json-schema <schema>` with `--allowedTools "Read,Grep,Glob,Bash(gh:*),Bash(git:*)"` and `cwd` = the worktree path. Hard 10-minute timeout.
  3. The modal renders the live event stream as raw text deltas while running.
  4. On final structured result, the orchestrator persists a `Review` row in SwiftData with the parsed payload, and the modal switches to displaying the raw structured JSON (no styled findings UI yet).
- This slice runs **single-flight only**: clicking Review on a second PR while one is running shows a "Review in progress" message and is rejected. Concurrency lands in slice 13.
- This slice has **no Jira context**: prompt sends only PR meta (title, body, author) plus an instruction to use `gh` to fetch the diff and any further context, and to return schema-conformant JSON.

Modules introduced or fleshed out:

- `WorktreeManager` — bare clone, fetch, worktree add, partial-clone cleanup on failure. SSH-vs-HTTPS choice cached.
- `ClaudeRunner` — spawn, line-by-line JSONL parse, `ClaudeEvent` enum (text delta, tool call, final result, error), 10-min timeout kill, cancellation hook.
- `ReviewStore` — SwiftData models `Review` and `Finding` (Finding is persisted but not yet displayed); `JiraTicket` and `WorktreeRecord` may be defined now or added in their respective slices.
- `ReviewOrchestrator` — composition root; this slice keeps the state machine simple (`running → completed | failed | timeout`); queueing and cancellation UI are slice 13.

## Output schema

Claude is invoked with this schema (also referenced by slice 08):

```json
{
  "summary": "string",
  "verdict": "approve | request_changes | comment",
  "findings": [
    {
      "severity": "blocker | major | minor | nit | praise",
      "file": "path/relative/to/repo.kt",
      "line": 42,
      "endLine": 45,
      "title": "short headline",
      "message": "1-3 sentences",
      "suggestion": "optional code fix or null"
    }
  ],
  "jira_alignment": {
    "matches_ticket": true,
    "notes": "string"
  }
}
```

For slice 07, `jira_alignment.matches_ticket` will be `null`/`false` (no Jira input).

## Acceptance criteria

- [ ] Review button visible on each Reviews-tab PR card.
- [ ] First click on a PR for a never-cloned repo triggers a bare clone with progress visible in the modal.
- [ ] Worktree appears at `~/.work-homepage/worktrees/<org>/<repo>/<pr#>/` checked out at the PR head SHA.
- [ ] Claude is spawned with `--allowedTools "Read,Grep,Glob,Bash(gh:*),Bash(git:*)"`, `cwd` = worktree.
- [ ] Live text deltas are visible in the modal during the run.
- [ ] Final structured result decodes against the schema and persists as a `Review` + `Finding` rows in SwiftData.
- [ ] Modal displays the raw structured JSON (pretty-printed) once the run completes.
- [ ] 10-minute timeout kills the process and marks the review `timeout` with stderr captured.
- [ ] Non-zero exit marks the review `failed` with stderr captured.
- [ ] Single-flight: clicking Review on a second PR while one is running surfaces a clear "in progress" rejection.
- [ ] No PATH leakage: every `git`/`claude`/`gh` invocation uses absolute path from `BinaryResolver`.

## Blocked by

- Issue 06 (BinaryResolver + first-run wizard)
