//
//  JiraBadgeView.swift
//  WorkHomepage
//
//  Slice 26 — Jira badge on PR cards.
//
//  A small clickable pill that resolves the Jira ticket key from a PR's head
//  branch name and links to the ticket. Renders `EmptyView` when:
//    - `branchName` is nil or carries no extractable key, or
//    - `baseURL` resolves to nil (Jira not configured in Settings).
//
//  `resolve(branchName:baseURL:)` is a static helper so tests can exercise the
//  logic without instantiating the view or touching the live `JiraConfig`.
//

import SwiftUI
import AppKit

struct JiraBadgeView: View {
    let branchName: String?

    var body: some View {
        if let resolved = Self.resolve(branchName: branchName, baseURL: JiraConfig.getBaseURL()) {
            Button {
                NSWorkspace.shared.open(resolved.url)
            } label: {
                Text(resolved.key)
                    .font(Font.appBody(size: 11, weight: .semibold))
                    .foregroundColor(Color.accentFern)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentFern.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.accentFern.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(resolved.key)
        } else {
            EmptyView()
        }
    }

    /// Pure helper that resolves a (key, url) pair from a branch name and a
    /// base URL string. Accepts `baseURL` as a parameter so callers — including
    /// unit tests — can supply it directly instead of reading `JiraConfig`.
    ///
    /// Returns nil when:
    ///   - `branchName` is nil,
    ///   - no Jira key can be extracted from the branch name,
    ///   - `baseURL` is nil or empty,
    ///   - the resulting URL string is malformed.
    static func resolve(branchName: String?, baseURL: String?) -> (key: String, url: URL)? {
        guard
            let branch = branchName,
            let key = TicketKeyExtractor.extract(branchName: branch),
            let raw = baseURL,
            !raw.isEmpty
        else { return nil }

        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/browse/\(key)") else { return nil }
        return (key, url)
    }
}
