# 23 — Custom Review Prompt Template

Source: PRD addendum US 62-69, CONTEXT.md "Review Prompt Template".

## What to build

A user-editable Review prompt template, with safety rails.

Modules:

1. **`PromptInterpolator`** (deep, pure, `Services/PromptInterpolator.swift`):
   - `static func interpolate(_ template: String, vars: [String: String]) -> String`. Replace every `{{key}}` occurrence (whitespace inside braces tolerated: `{{ key }}`).
   - `static func unknownVariables(in template: String, knownKeys: Set<String>) -> [String]`. Returns variable names referenced in the template that aren't in `knownKeys`.

2. **`ReviewPromptStore`** (deep, `Services/ReviewPromptStore.swift`):
   - Wraps a `UserDefaults` key (`reviewPromptTemplate`).
   - `func current() -> String` — returns user value if set, else `defaultTemplate`.
   - `func setCurrent(_ value: String)`.
   - `func reset()` — removes the key, restoring default.
   - `static let defaultTemplate: String` — the existing PR-body string from `OrchestratorPrompt.renderPRBody`, but with `{{repo}}`, `{{prNumber}}`, `{{branch}}`, `{{sha}}` placeholders instead of inline interpolation.

3. **`OrchestratorPrompt.build`** — modified:
   - Read `ReviewPromptStore().current()`.
   - Interpolate via `PromptInterpolator.interpolate(_, vars:)` with `{repo, prNumber, branch, sha}`.
   - If the resulting string does not contain `"Return JSON conformant to the provided schema"`, append the canonical schema directive ("Return JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files.").
   - Jira block continues to be code-rendered and prepended (unchanged from slice 11).

4. **`AppSettings`** — add `reviewPromptTemplate: String` accessor (writes to the same UserDefaults key as `ReviewPromptStore`).

5. **`SettingsView`** — new "Review Prompt" section:
   - Multi-line `TextEditor` bound to the template, monospaced font.
   - "Reset to default" button.
   - "Variables" footer: `{{repo}}`, `{{prNumber}}`, `{{branch}}`, `{{sha}}`.
   - **Live preview** pane: reuses `OrchestratorPrompt.build(repo: "acme/foo", prNumber: 123, branch: "feature/PROJ-1", sha: "abc1234", jira: <stub>)` and renders the result in a read-only scroll view.
   - **Unknown variable warning**: yellow callout listing any `{{...}}` tokens in the template that aren't in the known-keys set.
   - Note: "Schema directive auto-appended if missing."

## Acceptance criteria

- [ ] `PromptInterpolatorTests`: known vars interpolate; unknown vars left literal; repeated `{{key}}` replaces all; unbalanced `{{` ignored; `unknownVariables` returns expected list.
- [ ] `ReviewPromptStoreTests`: `current()` returns default when key absent; `setCurrent` + `current()` round-trips; `reset()` restores default.
- [ ] Existing `OrchestratorPromptTests` extended: with custom template, vars interpolate; missing schema directive auto-appended; Jira block unchanged.
- [ ] `SettingsView` Review Prompt section: editable, reset works, preview updates live, unknown-var callout appears for typos.
- [ ] End-to-end: edit template in Settings, click Review on a PR, prompt sent to Claude is the user's template (verified via the partial stream / log).
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 19 (Settings UI uses theme tokens)
