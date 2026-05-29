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
//  In addition to the key + link, the badge fetches the live ticket status
//  through `JiraClient` (cache-aware) and displays it inline as `KEY · Status`.
//  Status fetch is re-keyed on `refreshTick`: parent tabs bump the tick on
//  each refresh so the badge re-checks Jira. The cache layer keeps the
//  re-check cheap when nothing changed (HEAD-like projection on `updated`).
//

import SwiftUI
import AppKit
import SwiftData

struct JiraBadgeView: View {
    let branchName: String?
    /// Bumped by the parent tab on each refresh. Used as part of the `.task`
    /// id so the status fetch re-fires when the parent refreshes its data.
    /// Defaults to 0 for call sites that don't have a refresh notion
    /// (e.g. `ReviewSheet` — the sheet stays open while the underlying
    /// review runs, and the status is fetched once on appear).
    var refreshTick: Int = 0

    @Environment(\.modelContext) private var modelContext
    @State private var status: String?

    var body: some View {
        if let resolved = Self.resolve(branchName: branchName, baseURL: JiraConfig.getBaseURL()) {
            Button {
                NSWorkspace.shared.open(resolved.url)
            } label: {
                Text(displayText(key: resolved.key))
                    .font(Font.appBody(size: 11, weight: .semibold))
                    .foregroundColor(Color.accentFern)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentFern.opacity(0.12)))
                    .overlay(Capsule().stroke(Color.accentFern.opacity(0.3), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(displayText(key: resolved.key))
            .task(id: TaskKey(key: resolved.key, tick: refreshTick)) {
                await fetchStatus(key: resolved.key)
            }
        } else {
            EmptyView()
        }
    }

    private func displayText(key: String) -> String {
        if let status, !status.isEmpty {
            return "\(key) · \(status)"
        }
        return key
    }

    /// Hits `JiraClient.fetchTicket(key:)` and stores the status when present.
    /// Any error degrades the badge to key-only — Jira credentials may not be
    /// configured, the ticket may no longer exist, or the network may be down.
    /// None of those should remove the link to the ticket.
    @MainActor
    private func fetchStatus(key: String) async {
        let client = JiraClient(context: modelContext)
        do {
            if let ticket = try await client.fetchTicket(key: key) {
                let trimmed = ticket.status.trimmingCharacters(in: .whitespacesAndNewlines)
                status = trimmed.isEmpty ? nil : trimmed
            }
        } catch {
            // Silently drop — the key + link still work.
        }
    }

    /// Combined identity for `.task(id:)` — both the resolved ticket key and
    /// the parent refresh tick gate re-fetching. Branch changes (rename, head
    /// SHA churn that happens to swap branches) flow through `key` already
    /// because `resolve(branchName:)` re-derives it.
    private struct TaskKey: Hashable {
        let key: String
        let tick: Int
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

        // Defense in depth: even though JiraConfig.setBaseURL refuses non-
        // https inputs, an older defaults entry (or a manually-edited plist)
        // could still ship a `http://` or `javascript:` URL. We never want
        // NSWorkspace.shared.open to honor anything but https.
        guard JiraConfig.validateBaseURL(raw) else { return nil }

        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(trimmed)/browse/\(key)"),
              let scheme = url.scheme?.lowercased(), scheme == "https" else { return nil }
        return (key, url)
    }
}
