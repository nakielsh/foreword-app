//
//  Theme.swift
//  Foreword
//
//  Slice 19 — Botanical Garden theme: Font accessors and palette documentation.
//
//  == Color tokens ==
//
//  Color tokens (`Color.bgDeep`, `Color.accentFern`, etc.) are provided
//  automatically by the Xcode asset-catalog code-gen (`GeneratedAssetSymbols.swift`
//  from ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES).
//  They resolve to `SwiftUI.Color.init(.bgDeep)` under the hood.
//
//  == Palette derivation ==
//
//  Light values mirror the HTML `:root` block in index.html exactly.
//
//  Dark values use a hybrid strategy (ADR-0001):
//  - bg-deep:     hand-picked #1e2a23 (deep forest — cream→forest inversion)
//  - text-primary: hand-picked #e8e4d8 (warm cream — near-black→cream)
//  - bg-card / bg-card-hover: manual dark tones (white L=1.0 HSL-flips to
//    pure black; we use dark warm tones instead: #242120 / #1e1c12)
//  - All other tokens: HSL flip (rotate L to 1-L, keep H and S):
//
//      bg-surface   #edeae2 (H=43° L=0.90 S=0.17) → dark #1d1a12 (L=0.10)
//      text-secondary #5a6b5c (H=130° L=0.39 S=0.08) → dark #94a596 (L=0.61)
//      text-muted   #8a9588 (H=124° L=0.57 S=0.04) → dark #6c776a (L=0.43)
//      accent-fern  #4a7c59 (H=145° L=0.39 S=0.25) → dark #83b592 (L=0.61)
//      accent-marigold #f9a620 (H=39° L=0.55 S=0.94) → dark #df8c06 (L=0.45)
//      accent-terracotta #b7472a (H=12° L=0.44 S=0.62) → dark #d56548 (L=0.56)
//      accent-gray  #8a9588 (H=124° L=0.57 S=0.04) → dark #6c776a (L=0.43)
//
//  border-subtle/border-medium are stored at full opacity in the catalog;
//  each call site applies `.opacity(...)` for the rgba blending effect the
//  HTML uses (rgba(74,124,89,0.10) / rgba(74,124,89,0.20)).
//
//  == Font stack ==
//
//  display → Libre Baskerville (serif, bundled under Resources/Fonts/)
//  appBody → Source Sans 3 (sans-serif, bundled)
//  mono    → system monospaced (SF Mono / Menlo — not bundled)
//
//  Registered via ATSApplicationFontsPath = "Fonts" in Info.plist (injected
//  by INFOPLIST_KEY_ATSApplicationFontsPath in project build settings).
//
//  Fallback: if a bundled font fails to register, Font.custom automatically
//  falls back to the system serif/sans-serif.
//

import SwiftUI

// MARK: - Font accessors

extension Font {
    /// Serif display font (Libre Baskerville). Use for card titles, headings.
    static func display(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black:
            name = "LibreBaskerville-Bold"
        default:
            name = "LibreBaskerville-Regular"
        }
        return .custom(name, size: size)
    }

    /// Sans-serif body font (Source Sans 3). Use for body text, labels, captions.
    /// Named `appBody` to avoid collision with `Font.body` (SwiftUI system property).
    static func appBody(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let name: String
        switch weight {
        case .bold, .heavy, .black:
            name = "SourceSans3-Bold"
        case .semibold:
            name = "SourceSans3-Semibold"
        case .medium:
            name = "SourceSans3-Medium"
        default:
            name = "SourceSans3-Regular"
        }
        return .custom(name, size: size)
    }

    /// Monospaced font — system SF Mono / Menlo, not bundled.
    static func mono(size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }
}
