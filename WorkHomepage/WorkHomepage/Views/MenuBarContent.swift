//
//  MenuBarContent.swift
//  WorkHomepage
//
//  Slice 16 — MenuBarExtra companion.
//
//  Two SwiftUI views:
//
//   - `MenuBarLabel` — the icon/text shown in the system menu bar. Reads
//     `MenuBarCounts.shared` and re-renders live. When both counts are zero,
//     shows just an `eye.fill` SF Symbol so the bar stays clean. Otherwise
//     shows the symbol plus `R<awaiting> · ⚙<inFlight>` text.
//
//   - `MenuBarContent` — the dropdown menu shown when the user clicks the
//     label. Three items: Show window, Refresh Reviews, Quit. The window-
//     show path uses `NSApp.activate(...)` to bring the app to the front,
//     then opens the main window via the SwiftUI `openWindow` environment
//     action so the path also works after the user has closed the window.
//

import SwiftUI
import AppKit

/// Identifier used by the main `WindowGroup` so `openWindow(id:)` can recreate
/// it when "Show window" is invoked from the menu bar after the window was
/// closed. Kept as a constant so `WorkHomepageApp` and this view agree on the
/// string.
enum MenuBarWindowID {
    static let main = "WorkHomepageMain"
}

/// Identifier for the dedicated review `Window` scene. The review surface
/// runs in its own `NSWindow` (not a `.sheet`) so the main window can be
/// freely resized while a review is open — macOS attached sheets disable the
/// host window's resize handles for as long as they're up.
enum ReviewWindowID {
    static let main = "WorkHomepageReview"
}

/// The `MenuBarExtra`'s label. Re-renders whenever `MenuBarCounts.shared`
/// changes thanks to `@Observable`. Use `let` for the singleton — `@State`
/// for an externally-owned `@Observable` is an antipattern that misleads
/// SwiftUI's identity diffing without buying observation.
struct MenuBarLabel: View {
    private let counts = MenuBarCounts.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "eye.fill")
            if counts.awaitingReviews > 0 || counts.inFlightReviews > 0 {
                Text(labelText)
                    .font(Font.mono(size: 12))
            }
        }
    }

    /// `R<awaiting> · ⚙<in-flight>`. The middle dot is U+00B7 (`·`).
    private var labelText: String {
        "R\(counts.awaitingReviews) · ⚙\(counts.inFlightReviews)"
    }
}

/// The dropdown content for the `MenuBarExtra`. Three actions; everything
/// dispatches via `NSApp` and `NotificationCenter` so the menu has no direct
/// dependency on the main window's view hierarchy.
struct MenuBarContent: View {
    /// Used to (re)open the main window when the user picks "Show window"
    /// after closing it. Pulled from the environment because the
    /// `MenuBarExtra` scene gets its own SwiftUI environment from
    /// `WorkHomepageApp`.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show window") {
            showMainWindow()
        }
        .keyboardShortcut("o", modifiers: [.command])

        Button("Refresh Reviews") {
            // Slice 16 only posts; the receiver lives in a future slice that
            // may modify `ReviewsTab`. See `MenuBarCounts.swift` for the
            // notification names and the rationale for the seam.
            NotificationCenter.default.post(name: .refreshReviewsRequested, object: nil)
        }
        .keyboardShortcut("r", modifiers: [.command])

        Divider()

        Button("Quit") {
            // Slice 13 will hook a clean shutdown that cancels any in-flight
            // reviews before terminate. For slice 16, `NSApp.terminate` is
            // sufficient.
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }

    /// Brings the main window forward, recreating it if the user closed it.
    /// `NSApp.activate(...)` flips us to the foreground; `openWindow(id:)`
    /// handles the "no visible window" case (SwiftUI will reuse an existing
    /// instance if one is already alive).
    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: MenuBarWindowID.main)
    }
}
