# Theme palette: HTML tokens with hand-picked dark anchors, algorithmic flip elsewhere

The macOS app must match the HTML dashboard's Botanical Garden identity (cream paper, fern green, marigold, terracotta, Libre Baskerville + Source Sans 3). The HTML was light-only; the app must support dark mode because system theming is a baseline macOS expectation.

We store the same hex tokens as the HTML in the asset catalog (one `.colorset` per token) and let SwiftUI resolve light vs. dark automatically. We hand-pick dark variants for **only** two anchor tokens — `bg-deep` (cream → deep forest) and `text-primary` (almost-black → muted cream) — and HSL-flip the rest at color-resource generation time. Pure algorithmic flip looked muddy on the fern green and lost the cream warmth entirely; full hand-pick was more design effort than this self-use app warrants. The hybrid keeps the cheap path everywhere it works and pays the design cost only where it's load-bearing.

## Considered options

- **Pure HSL flip** — rejected: fern goes fluorescent, cream goes near-black, identity dies in dark mode.
- **Full hand-picked dark palette** — rejected: design effort disproportionate for solo-use; many tokens (accent amber/red/gray) flip cleanly without intervention.
- **Pixel-mirror HTML, force light only** — rejected: standard macOS apps respect system theme; pinning to light feels foreign.

## Consequences

Two tokens (`bg-deep`, `text-primary`) need manual updates when the light palette changes. (Update: `bg-card` and `bg-card-hover` later got hand-picked dark tones too, because white HSL-flips to pure black. The full derivation table lives in the header of `Theme.swift`.) The rest stay in sync automatically. The Settings appearance toggle (Light / Dark / System, default System) lets the user pin if a specific token looks wrong in either mode without re-derivation.
