# 20 — Theme rollout to remaining views

Source: PRD addendum US 48, 51. Continuation of slice 19.

## What to build

Apply the Botanical Garden tokens + fonts (from slice 19's `Theme.swift` + asset catalog) to every view not already styled in slice 19.

Views to convert:

- `MyPRsTab.swift` and the PR card it renders
- `SessionsTab.swift` and the session card
- `DeploysTab.swift` and the deployment card
- `ReviewSheet.swift` (the Claude review modal — header, finding rows, Jira block, stream pane, all severity treatments)
- `SettingsView.swift` (sections other than the Appearance picker added in slice 19)
- `SidebarView.swift`
- `MenuBarContent.swift`
- `FirstRunWizard.swift`
- `TokenPromptSheet.swift`

For each view, replace every hardcoded `Color.gray/orange/purple/blue` and every default system font usage with the typed `Color.*` / `Font.*` accessors. Severity colors map to accent tokens (blocker → accent-terracotta, major → accent-marigold, minor → accent-fern, nit → accent-gray, praise → accent-fern). Status colors map sensibly (approved → accent-fern, changes-requested/dismissed → accent-terracotta, draft → accent-gray, pending → accent-marigold).

## Acceptance criteria

- [ ] No hardcoded `Color.gray.opacity(...)`, `Color.orange`, `Color.purple`, `Color.blue`, `Color.red`, `Color.green` literals remain in any view file.
- [ ] No `Font.system(...)`, `.font(.headline)`, `.font(.callout)` etc. left at sites that should use serif display or sans body — only legitimate uses (e.g., monospace for code) remain.
- [ ] All views look consistent with Reviews tab in both light and dark mode.
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 19
