//
//  MonogramRenderer.swift
//  WorkHomepage
//
//  Slice 21 — Generates deterministic monogram NSImages as fallbacks when
//  an avatar URL is unavailable or fails to load.
//
//  The hash function is FNV-1a (32-bit) rather than Swift's randomized
//  `Hasher`, so the same login always produces the same hue across launches.
//

import AppKit
import Foundation

enum MonogramRenderer {

    /// Returns a circular `size × size` NSImage containing the first character
    /// of `login` drawn in white on a stable hash-derived background color.
    ///
    /// - Deterministic: same `login` + same `size` → byte-identical PNG.
    /// - Empty / whitespace login → renders `?`.
    /// - Numeric prefix (`123-bot`) → first character `1`.
    /// - Non-ASCII (`Åsa`) → first scalar uppercased.
    static func render(login: String, size: CGFloat) -> NSImage {
        let glyph = firstGlyph(for: login)
        let hue = stableHue(for: login)
        let bg = NSColor(hue: hue / 360.0, saturation: 0.45, brightness: 0.65, alpha: 1.0)

        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()

        // Clip to circle.
        let circlePath = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: size, height: size))
        circlePath.addClip()

        // Fill background.
        bg.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()

        // Draw glyph centered.
        let font: NSFont = NSFont(name: "LibreBaskerville-Regular", size: size * 0.5)
            ?? NSFont.systemFont(ofSize: size * 0.5)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let string = NSAttributedString(string: glyph, attributes: attrs)
        let textSize = string.size()
        let origin = NSPoint(
            x: (size - textSize.width) / 2.0,
            y: (size - textSize.height) / 2.0
        )
        string.draw(at: origin)

        image.unlockFocus()
        return image
    }

    // MARK: - Private helpers

    /// Derives the first displayable glyph from `login`.
    /// Whitespace / empty → "?", otherwise the first Unicode scalar uppercased.
    private static func firstGlyph(for login: String) -> String {
        let trimmed = login.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.unicodeScalars.first else { return "?" }
        let upper = String(first).uppercased()
        // uppercased() can expand one scalar to multiple chars (e.g. German ß →
        // SS). Take the first character only so the monogram stays single-glyph.
        return String(upper.prefix(1))
    }

    /// Stable FNV-1a 32-bit hash → hue in [0, 360).
    /// FNV-1a is simple, collision-resistant enough for this use, and produces
    /// the same value across processes — unlike Swift's randomized `Hasher`.
    private static func stableHue(for login: String) -> CGFloat {
        var hash: UInt32 = 2_166_136_261 // FNV-1a 32-bit offset basis
        for byte in login.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619 // FNV-1a 32-bit prime (0x01000193)
        }
        // Use all 32 bits for hue distribution.
        return CGFloat(hash % 360)
    }
}
