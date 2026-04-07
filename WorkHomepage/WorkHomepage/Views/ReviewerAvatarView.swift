//
//  ReviewerAvatarView.swift
//  WorkHomepage
//
//  Slice 21 — Circular avatar image with monogram placeholder and role tooltip.
//
//  Shows a 24px (default) circle:
//  - While loading: monogram via MonogramRenderer (no spinner).
//  - On success:    the downloaded NSImage clipped to circle.
//  - On failure:    monogram (AvatarLoader returns monogram on non-2xx / nil).
//
//  Not clickable — wraps the image in a plain non-interactive view.
//

import SwiftUI
import AppKit

// MARK: - AvatarRole

/// Semantic role of the person shown by a `ReviewerAvatarView`.
enum AvatarRole: Equatable {
    case author
    case reviewer(status: ReviewerStatus)
}

// MARK: - ReviewerAvatarView

struct ReviewerAvatarView: View {

    let login: String
    let avatarURL: URL?
    let role: AvatarRole
    var size: CGFloat = 24
    /// Optional ring drawn around the avatar circle. 1pt stroke.
    /// Nil = no ring (default, back-compat).
    var borderColor: Color? = nil

    @State private var image: NSImage? = nil

    var body: some View {
        avatarCircle
            .help(tooltip)
            .task(id: avatarURL?.absoluteString ?? login) {
                image = await AvatarLoader.shared.image(for: avatarURL, login: login)
            }
    }

    // MARK: - Private views

    @ViewBuilder
    private var avatarCircle: some View {
        let resolved: NSImage = image ?? MonogramRenderer.render(login: login, size: size * 2)
        Image(nsImage: resolved)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay {
                if let borderColor {
                    Circle().strokeBorder(borderColor, lineWidth: 1)
                }
            }
            .allowsHitTesting(false)
    }

    // MARK: - Tooltip

    private var tooltip: String {
        switch role {
        case .author:
            return "@\(login) — Author"
        case .reviewer(let status):
            return "@\(login) — Reviewer (\(statusLabel(status)))"
        }
    }

    private func statusLabel(_ status: ReviewerStatus) -> String {
        switch status {
        case .approved:          return "Approved"
        case .changesRequested:  return "Changes requested"
        case .commented:         return "Commented"
        case .dismissed:         return "Dismissed"
        case .pending:           return "Pending"
        case .reRequested:       return "Re-review requested"
        }
    }
}
