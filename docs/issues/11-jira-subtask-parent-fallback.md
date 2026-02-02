# 11 — Jira subtask parent fallback

## What to build

When the matched Jira ticket is a subtask whose own description is empty or thin, also fetch the parent ticket and include its description in the prompt. This matches the team's working pattern (parent has the real description, subtasks are breakdowns with title-only).

`JiraClient` extension:

- After fetching a ticket, check `fields.parent.key`. If absent, no change.
- If present AND the subtask's own description is missing OR shorter than ~100 characters of plaintext, fetch the parent (one level only — never recurse further).
- The `Ticket` model gains an optional `parent: Ticket?` populated only in this case.

Prompt injection:

- When parent is attached, the Jira block in the prompt becomes:

  ```
  Jira: <KEY> (subtask of <PARENT_KEY>)
  Subtask title: <subtask summary>
  Subtask description: <subtask plaintext or "(empty)">

  Parent <PARENT_KEY> title: <parent summary>
  Parent description: <parent plaintext>
  ```

- When subtask description is rich, parent is NOT fetched and the prompt looks identical to slice 10.

## Acceptance criteria

- [ ] Subtask with empty description triggers a parent fetch; parent description is included in the prompt.
- [ ] Subtask with description shorter than ~100 chars triggers parent fetch.
- [ ] Subtask with rich description does NOT trigger parent fetch (one Jira request only).
- [ ] Top-level (non-subtask) tickets behave identically to slice 10.
- [ ] Modal header in slice 08 surfaces "(subtask of PARENT)" when parent was used.
- [ ] No infinite recursion: parent's parent is never fetched.

## Blocked by

- Issue 10 (Jira basic)
