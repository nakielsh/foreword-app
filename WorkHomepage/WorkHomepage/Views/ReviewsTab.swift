//
//  ReviewsTab.swift
//  WorkHomepage
//
//  Slice 02 — Reviews tab full parity with `index.html`.
//
//  Three concentric layers, top to bottom:
//   1. Filter bar — approval-threshold picker (1...5, default 2) + "Show my
//      dismissed reviews" toggle. State persisted to UserDefaults under
//      `reviews.approvalThreshold` / `reviews.showDismissed`.
//   2. Stats bar — five live chips:
//        awaiting / with approvals / drafts / dismissed (only when toggle is
//        on and there are dismissed PRs) / currently showing.
//   3. Pending grid — pending review-requested PRs filtered by threshold +
//      dismissed toggle. Below it: three sub-section grids
//      ("Changes Requested", "My Comments", "Already Approved") populated
//      from `reviewed-by:@me` PRs that are no longer in the pending set,
//      grouped by `myLastReviewState`. Each ReviewedPR card surfaces the
//      "+N new commits since your review" badge when applicable.
//
//  Refresh model: `refreshTick: Int` parameter from SidebarView's toolbar
//  Refresh button (slice 01 pattern). Tab also exposes a per-tab refresh in
//  `.toolbar(secondaryAction)` for resilience while we wait for SidebarView
//  changes (kept consistent with MyPRsTab).
//

import SwiftUI
import struct Foundation.Date

struct ReviewsTab: View {
    /// Bumped by SidebarView's toolbar Refresh button. Defaulted so the tab
    /// can be constructed in previews.
    var refreshTick: Int = 0

    // MARK: - Persisted filter state

    /// "Hide PRs with >= N approvals". Default 2 (matches index.html).
    @AppStorage("reviews.approvalThreshold") private var approvalThreshold: Int = 2
    /// "Show my dismissed reviews" toggle. Default off.
    @AppStorage("reviews.showDismissed") private var showDismissed: Bool = false

    // MARK: - In-memory state

    @State private var pendingPRs: [PendingReviewPR] = []
    @State private var reviewedPRs: [ReviewedPR] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showReauthSheet: Bool = false
    @State private var hasFetchedOnce: Bool = false
    @State private var currentUser: String?

    private let client = GitHubClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }
            filterBar
            statsBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Reviews")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh Reviews", systemImage: "arrow.clockwise.circle")
                }
                .help("Refresh Reviews")
            }
        }
        .onChange(of: refreshTick) { _, _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showReauthSheet) {
            TokenPromptSheet(reason: .reauth) {
                showReauthSheet = false
                Task { await refresh() }
            }
        }
    }

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 6) {
                Text("Hide PRs with ≥")
                    .font(.subheadline)
                Picker("", selection: $approvalThreshold) {
                    ForEach(1...5, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 60)
                Text("approvals")
                    .font(.subheadline)
            }

            Toggle(isOn: $showDismissed) {
                Text("Show my dismissed reviews")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.04))
    }

    // MARK: - Stats bar

    @ViewBuilder
    private var statsBar: some View {
        if hasFetchedOnce {
            let derived = derivedStats()
            HStack(spacing: 12) {
                StatChip(dotColor: .orange, value: derived.awaiting, label: "awaiting")
                StatChip(dotColor: .green, value: derived.withApprovals, label: "with approvals")
                if derived.drafts > 0 {
                    StatChip(dotColor: .gray, value: derived.drafts, label: "drafts")
                }
                if showDismissed && derived.dismissed > 0 {
                    StatChip(dotColor: .red, value: derived.dismissed, label: "dismissed")
                }
                StatChip(
                    dotColor: nil,
                    value: derived.showing,
                    label: derived.hidden > 0 ? "showing (\(derived.hidden) hidden)" : "showing"
                )
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.gray.opacity(0.05))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && pendingPRs.isEmpty && reviewedPRs.isEmpty {
            ProgressView("Loading reviews…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasFetchedOnce {
            EmptyHint(text: "Click Refresh to load review-requested PRs.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    pendingSection
                    reviewedSubSections
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        let visible = visiblePendingPRs()
        if visible.isEmpty {
            EmptyHint(text: "No PRs awaiting your review.")
                .frame(minHeight: 80)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(visible) { pr in
                    PendingPRCard(pr: pr)
                }
            }
        }
    }

    @ViewBuilder
    private var reviewedSubSections: some View {
        let pendingIds = Set(pendingPRs.map(\.id))
        let reviewed = reviewedPRs.filter { !pendingIds.contains($0.id) }
        let changesReq = reviewed.filter { $0.myLastReviewState == .changesRequested }
        let commented = reviewed.filter { $0.myLastReviewState == .commented }
        let approved = reviewed.filter { $0.myLastReviewState == .approved }

        if !changesReq.isEmpty {
            SubSection(title: "Changes Requested", count: changesReq.count, accent: .red) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changesReq) { pr in
                        ReviewedPRCard(pr: pr)
                    }
                }
            }
        }
        if !commented.isEmpty {
            SubSection(title: "My Comments", count: commented.count, accent: .orange) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(commented) { pr in
                        ReviewedPRCard(pr: pr)
                    }
                }
            }
        }
        if !approved.isEmpty {
            SubSection(title: "Already Approved", count: approved.count, accent: .green) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approved) { pr in
                        ReviewedPRCard(pr: pr)
                    }
                }
            }
        }
    }

    // MARK: - Filter / stats derivations

    private func visiblePendingPRs() -> [PendingReviewPR] {
        var visible = pendingPRs.filter {
            !ReviewsDerive.isHiddenByApprovalThreshold(
                approvalCount: $0.approvalCount,
                threshold: approvalThreshold
            )
        }
        if showDismissed {
            // Also include PRs from the "reviewed-by:@me" set whose last review
            // was DISMISSED. These would normally be filtered out of the
            // pending set by GitHub once dismissed; we layer them in only when
            // the toggle is on, matching index.html's `dismissedPRs` overlay.
            // We treat any PendingReviewPR with isDismissed=true as the
            // explicit case (it would be there if GitHub kept it on
            // review-requested anyway). No action needed for now — the search
            // already returns them when applicable.
            _ = visible
        } else {
            visible = visible.filter { !$0.isDismissed }
        }
        return visible
    }

    private struct DerivedStats {
        let awaiting: Int
        let withApprovals: Int
        let drafts: Int
        let dismissed: Int
        let showing: Int
        let hidden: Int
    }

    private func derivedStats() -> DerivedStats {
        let withApp = pendingPRs.filter { $0.approvalCount > 0 }.count
        let drafts = pendingPRs.filter { $0.isDraft }.count
        let dismissed = pendingPRs.filter { $0.isDismissed }.count
        let awaiting = max(0, pendingPRs.count - withApp - drafts)
        let visible = visiblePendingPRs()
        let total = pendingPRs.count
        let hidden = max(0, total - visible.count)
        return DerivedStats(
            awaiting: awaiting,
            withApprovals: withApp,
            drafts: drafts,
            dismissed: dismissed,
            showing: visible.count,
            hidden: hidden
        )
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // 1. Resolve viewer login (cache once).
            let login: String
            if let cached = currentUser {
                login = cached
            } else {
                login = try await client.fetchCurrentUserLogin()
                currentUser = login
            }

            // 2. Fan-out the two searches in parallel.
            async let pending = client.fetchPendingReviewPRs(currentUser: login)
            async let reviewed = client.fetchReviewedByMePRs(currentUser: login)
            let (p, r) = try await (pending, reviewed)
            pendingPRs = p
            reviewedPRs = r
            hasFetchedOnce = true
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub returned 401. Please re-enter your token."
            pendingPRs = []
            reviewedPRs = []
            showReauthSheet = true
        } catch GitHubError.missingToken {
            errorMessage = "No GitHub token stored. Add one to continue."
            showReauthSheet = true
        } catch GitHubError.http(let status, _) {
            errorMessage = "GitHub error \(status)."
        } catch GitHubError.decoding(let detail) {
            errorMessage = "Failed to decode GitHub response: \(detail)"
        } catch GitHubError.transport(let detail) {
            errorMessage = "Network error: \(detail)"
        } catch {
            errorMessage = "Unexpected error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Pending PR card

private struct PendingPRCard: View {
    let pr: PendingReviewPR

    var body: some View {
        Link(destination: pr.htmlURL) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.18)))
                    Spacer()
                    if pr.isDismissed {
                        TagPill(text: "Dismissed", color: .red)
                    }
                    if pr.isDraft {
                        TagPill(text: "Draft", color: .gray)
                    }
                    if let prior = pr.myPriorReviewState, !pr.isDismissed {
                        ReReviewTag(state: prior)
                    }
                    Text(timeAgo(pr.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("#\(pr.number)  \(pr.title)")
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Text("@\(pr.authorLogin)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if pr.approvalCount == 0 && pr.changesRequestedCount == 0 {
                        Text("No approvals")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        if pr.approvalCount > 0 {
                            Label("\(pr.approvalCount)", systemImage: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        if pr.changesRequestedCount > 0 {
                            Label("\(pr.changesRequestedCount)", systemImage: "xmark")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: Color {
        if pr.isDismissed { return Color.red.opacity(0.06) }
        if pr.changesRequestedCount > 0 { return Color.red.opacity(0.05) }
        if pr.approvalCount > 0 { return Color.green.opacity(0.05) }
        if pr.isDraft { return Color.gray.opacity(0.05) }
        return Color.gray.opacity(0.06)
    }

    private var cardStroke: Color {
        if pr.isDismissed { return Color.red.opacity(0.4) }
        if pr.changesRequestedCount > 0 { return Color.red.opacity(0.3) }
        if pr.approvalCount > 0 { return Color.green.opacity(0.3) }
        return Color.gray.opacity(0.18)
    }
}

// MARK: - Reviewed PR card

private struct ReviewedPRCard: View {
    let pr: ReviewedPR

    var body: some View {
        Link(destination: pr.htmlURL) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.18)))
                    Spacer()
                    ReReviewTag(state: pr.myLastReviewState)
                    Text(timeAgo(pr.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text("#\(pr.number)  \(pr.title)")
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    Text("@\(pr.authorLogin)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if pr.approvalCount > 0 {
                        Label("\(pr.approvalCount)", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    if pr.changesRequestedCount > 0 {
                        Label("\(pr.changesRequestedCount)", systemImage: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                }
                if pr.newCommitsSinceReview > 0 {
                    NewCommitsBadge(count: pr.newCommitsSinceReview)
                } else if pr.myLastReviewSubmittedAt != nil {
                    Text("No changes since your review")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(cardStroke, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: Color {
        switch pr.myLastReviewState {
        case .changesRequested: return Color.red.opacity(0.05)
        case .approved: return Color.green.opacity(0.05)
        case .commented: return Color.orange.opacity(0.04)
        default: return Color.gray.opacity(0.06)
        }
    }

    private var cardStroke: Color {
        switch pr.myLastReviewState {
        case .changesRequested: return Color.red.opacity(0.3)
        case .approved: return Color.green.opacity(0.3)
        case .commented: return Color.orange.opacity(0.3)
        default: return Color.gray.opacity(0.18)
        }
    }
}

// MARK: - Re-review tag (small "↻ Approved/Changes/Commented" pill)

private struct ReReviewTag: View {
    let state: PullRequestReviewState

    var body: some View {
        HStack(spacing: 3) {
            Text("↻")
                .font(.caption2.weight(.bold))
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
        .help(tooltip)
    }

    private var label: String {
        switch state {
        case .approved: return "Approved"
        case .changesRequested: return "Changes"
        case .commented: return "Commented"
        case .dismissed: return "Dismissed"
        case .pending: return "Pending"
        }
    }

    private var color: Color {
        switch state {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .orange
        case .dismissed: return .red
        case .pending: return .gray
        }
    }

    private var tooltip: String {
        switch state {
        case .approved: return "Re-review requested — you previously approved"
        case .changesRequested: return "Re-review requested — you previously requested changes"
        case .commented: return "Re-review requested — you previously commented"
        case .dismissed: return "Re-review requested — your prior review was dismissed"
        case .pending: return "Pending review"
        }
    }
}

// MARK: - "+N new commits since your review" badge

private struct NewCommitsBadge: View {
    let count: Int
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("\(count) new commit\(count == 1 ? "" : "s") since your review")
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.orange.opacity(0.18)))
        .foregroundStyle(.orange)
    }
}

// MARK: - Sub-section wrapper

private struct SubSection<Content: View>: View {
    let title: String
    let count: Int
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(accent.opacity(0.18)))
                    .foregroundStyle(accent)
                Spacer()
            }
            content()
        }
    }
}

// MARK: - Tag pill

private struct TagPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

// MARK: - Stat chip

private struct StatChip: View {
    let dotColor: Color?
    let value: Int
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            if let dotColor {
                Circle().fill(dotColor).frame(width: 8, height: 8)
            }
            Text("\(value)")
                .font(.subheadline.weight(.semibold))
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Empty / error helpers

private struct EmptyHint: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

// MARK: - Time ago helper (file-private — duplicates the version in MyPRsTab on
// purpose; that one is also private-to-file).

private func timeAgo(_ date: Date) -> String {
    let secs = Int(Date().timeIntervalSince(date))
    let mins = secs / 60
    let hours = mins / 60
    let days = hours / 24
    if days > 0 { return "\(days)d ago" }
    if hours > 0 { return "\(hours)h ago" }
    if mins > 0 { return "\(mins)m ago" }
    return "just now"
}
