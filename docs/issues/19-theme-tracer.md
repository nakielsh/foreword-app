# 19 — Theme tracer (Botanical Garden palette + fonts + appearance toggle)

Source: PRD addendum US 48-52, ADR-0001, CONTEXT.md "Theme".

## What to build

Bring the Botanical Garden visual identity from `index.html` into the macOS app, end-to-end on the Reviews tab, plus the foundation every other view will reuse.

Concrete deliverables:

1. **Bundled fonts** — Libre Baskerville (Regular/Bold/Italic) + Source Sans 3 (Regular/Medium/SemiBold/Bold). Drop `.ttf`s under `WorkHomepage/Resources/Fonts/`. Register in `Info.plist` via `ATSApplicationFontsPath` (macOS) or per-file `Fonts provided by application` array. SIL OFL licenses already permit.
2. **Asset catalog tokens** — one `.colorset` per token, both `Any Appearance` and `Dark Appearance` entries. Tokens (mirror HTML `:root`):
   - `bg-deep` (#f5f3ed light / hand-picked dark e.g. `#1e2a23`)
   - `bg-surface` (#edeae2 light / HSL-flipped dark)
   - `bg-card` (#ffffff light / HSL-flipped dark)
   - `bg-card-hover` (#faf9f6 light / HSL-flipped dark)
   - `border-subtle`, `border-medium`
   - `text-primary` (#2c3e2d light / hand-picked dark e.g. `#e8e4d8`)
   - `text-secondary`, `text-muted`
   - `accent-fern` (#4a7c59), `accent-marigold` (#f9a620), `accent-terracotta` (#b7472a), `accent-gray` (#8a9588)
   Two anchors hand-picked (bg-deep, text-primary). All others HSL-flipped at design time and committed to the catalog.
3. **`Theme.swift`** — typed accessors: `Color.bgDeep`, `Color.bgSurface`, `Color.accentFern`, ..., `Font.display(size: CGFloat, weight: Font.Weight = .regular) -> Font`, `Font.body(size:)`, `Font.mono(size:)`. Wraps `Color("bg-deep", bundle: .main)` and `Font.custom("LibreBaskerville-Regular", size: ...)`.
4. **`AppSettings`** — add `appearance: Appearance` enum (`light`, `dark`, `system`, default `.system`). Persist to UserDefaults under `appearance`.
5. **`SettingsView`** — new "Appearance" section with `Picker` bound to `AppSettings.appearance`.
6. **`WorkHomepageApp`** — apply `.preferredColorScheme(...)` at root from `AppSettings.appearance`.
7. **Reviews tab styled end-to-end** — apply tokens + fonts to `ReviewsTab.swift` and the PR card view it renders. Cards use `bg-card`, hover uses `bg-card-hover`, borders use `border-subtle`, headers use `Font.display`, body uses `Font.body`, severity-style accents from accent tokens. Background of the tab area uses `bg-deep`.

Out of scope this slice: rolling out tokens to MyPRs, Sessions, Deploys, ReviewSheet, Settings (other sections), Sidebar, MenuBarExtra, FirstRunWizard, TokenPromptSheet — those land in slice 20.

## Acceptance criteria

- [ ] Fonts ship in app bundle and load on first launch (verified by `NSFont.fontNames(forFamily:)` showing both families).
- [ ] All Botanical Garden tokens defined as `.colorset`s with light + dark entries.
- [ ] `Theme.swift` provides typed `Color` and `Font` accessors used everywhere instead of literals.
- [ ] `AppSettings.appearance` round-trips through UserDefaults.
- [ ] Settings → Appearance picker switches the live app between Light, Dark, and System.
- [ ] Reviews tab visually matches the Botanical Garden palette (cream paper, fern green accents, serif headings).
- [ ] Light + dark mode screenshots reviewed and approved.
- [ ] No `Color.gray.opacity(...)`, `Color.orange`, `Color.purple`, `Color.blue` literals remain in Reviews tab files — all replaced by tokens.
- [ ] App builds clean (`xcodebuild -scheme WorkHomepage -configuration Debug build`).
- [ ] Tests pass (`xcodebuild test`).

## Blocked by

- None — can start immediately.
