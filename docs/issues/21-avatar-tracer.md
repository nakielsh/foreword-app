# 21 — Avatar tracer (Reviews PR card author)

Source: PRD addendum US 53, 57-61.

## What to build

Show GitHub author avatars on Reviews PR cards with hover tooltips. Build the supporting modules so slice 22 can extend them to other surfaces with zero new infrastructure.

Modules:

1. **`AvatarLoader`** (deep, `Services/AvatarLoader.swift`):
   - Public surface: `func image(for url: URL?, login: String) async -> NSImage`.
   - In-memory `NSCache<NSURL, NSImage>` only (per ADR scope, no disk).
   - On nil URL or non-2xx response: returns `MonogramRenderer.render(login: login, size: 48)`.
   - URLSession with cooperative cancellation. Fetch once per URL; subsequent calls return cached.

2. **`MonogramRenderer`** (deep, pure, `Services/MonogramRenderer.swift`):
   - Public surface: `static func render(login: String, size: CGFloat) -> NSImage`.
   - Hash login (use a stable hash, not `Swift.Hasher` which is randomized per-launch — implement FNV-1a or similar).
   - Hash → hue (0-360); circle filled with `NSColor(hue: ..., saturation: 0.45, brightness: 0.65, alpha: 1)`.
   - First letter of login uppercased, rendered centered in white using `Font.display` size = `size * 0.5`.
   - Empty login → `?` glyph.

3. **`ReviewerAvatarView`** (View, `Views/ReviewerAvatarView.swift`):
   - Inputs: `login: String`, `avatarURL: URL?`, `role: AvatarRole` (enum: `author`, `reviewer(status: ReviewerStatus)`).
   - Renders 24px circle, async loads via `AvatarLoader`, shows monogram while loading or on failure.
   - `.help(...)` tooltip:
     - `author` → `@<login> — Author`
     - `reviewer(.approved)` → `@<login> — Reviewer (Approved)`
     - etc., one human-readable status string per `ReviewerStatus`.
   - Not clickable (per Q6 grilling).

Apply on Reviews tab:
- The pending PR card and the three reviewed-by-me sub-sections (Changes Requested, My Comments, Already Approved). All four are author-only (you are the reviewer).
- Render avatar before the author login text. Use `Font.body` for the login itself.

## Acceptance criteria

- [ ] `AvatarLoaderTests`: cache hit returns same `NSImage`; nil URL returns monogram; non-2xx falls back to monogram; cancellation propagates.
- [ ] `MonogramRendererTests`: same login → byte-identical image; different logins → different hues; non-ASCII / empty / numeric handled.
- [ ] Reviews tab pending PR cards show 24px author avatars with login + tooltip.
- [ ] Reviews tab Changes Requested / My Comments / Already Approved sub-sections all show author avatars.
- [ ] Hover tooltip reads `@<login> — Author`.
- [ ] No avatar is clickable.
- [ ] App builds clean.
- [ ] Tests pass.

## Blocked by

- Issue 19 (theme tokens used for monogram/border colors)
