# 10 — Jira basic (extractor + client + prompt injection)

## What to build

Wire Jira context into the review prompt.

`TicketKeyExtractor` (pure, deep, easy to unit-test):

- Public surface: `extract(branchName: String) -> String?`.
- Regex: `(feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)`.
- Returns capture group 2; nil if no match.

`JiraClient`:

- Public surface: `fetchTicket(key: String) -> Ticket?` where `Ticket` is `(summary, description, status, issuetype, priority, parentKey?)`.
- Atlassian Cloud, basic auth using `email:apiToken` from Keychain (`jira.email`, `jira.token`, `jira.baseURL`).
- ADF (Atlassian Document Format) descriptions flattened to plaintext via a small recursive walk that concatenates `text` nodes and emits `\n\n` for paragraph/heading boundaries. No real renderer needed.
- This slice does NOT yet handle the parent fallback (slice 11) or caching (slice 12). `parentKey` is captured for use by slice 11 but no extra fetch happens here.

Prompt injection:

- Before invoking `ClaudeRunner`, the orchestrator extracts the ticket key from the PR's head branch. If a key is found, it fetches the ticket and prepends a Jira block to the prompt:

  ```
  Jira: <KEY>
  Title: <summary>
  Type: <issuetype>  Status: <status>  Priority: <priority>
  Description:
  <plaintext description>
  ```

- If no key is detected, the prompt sets `Jira: null` and the run proceeds unchanged from slice 07.
- The modal header (slice 08) shows which Jira key was used (or "No ticket detected").

## Acceptance criteria

- [ ] `TicketKeyExtractor` correctly returns the key for `feature/PROJ-123`, `bugfix/PROJ-456`, `hotfix/PROJ-1`, `chore/AB-9999`, `task/X-1`.
- [ ] Returns nil for `main`, `master`, `dependabot/...`, branches with no recognized prefix.
- [ ] When two keys appear in the branch, the first match wins.
- [ ] `JiraClient` authenticates against Atlassian Cloud with email + API token from Keychain.
- [ ] ADF descriptions flatten correctly to plaintext for typical Jira descriptions (paragraphs, headings, bullets).
- [ ] When a ticket is found, the prompt includes the Jira block.
- [ ] When no ticket is detected, the run proceeds with `Jira: null` and the modal indicates "No ticket detected".
- [ ] Jira auth failure surfaces a clear error and does not block the review (the run proceeds without Jira context).

## Blocked by

- Issue 07 (Tracer bullet — end-to-end review)
