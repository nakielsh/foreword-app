//
//  MyPRsTab.swift
//  WorkHomepage
//
//  Slice 03 — My PRs tab parity with `index.html`.
//
//  Refresh-driven via the global toolbar `refreshTick` mechanism (same pattern
//  as ReviewsTab). On each tick we:
//   1. Resolve current user login (cached after first success).
//   2. Fetch authored open PRs (REST).
//   3. For each PR, fetch per-reviewer status + threads + comment count (GraphQL).
//
//  Each card renders: title + repo + #number + draft badge, per-reviewer status
//  badges, threads breakdown ("awaiting you" / "awaiting others"), total
//  comment count. Stats bar above the cards mirrors the original HTML.
//

import SwiftUI

struct MyPRsTab: View {
    /// Persistent data container owned by SidebarView. Survives tab switches
    /// so the loaded PR rows don't disappear when the user clicks away and
    /// back.
    @Bindable var vm: MyPRsViewModel
    /// Bumped by SidebarView's toolbar Refresh button.
    var refreshTick: Int = 0

    // MARK: - Transient UI state (does not need to survive tab switches)

    @State private var showReauthSheet: Bool = false

    private let client = GitHubClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = vm.errorMessage {
                ErrorBanner(message: errorMessage)
            }
            statsBar
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("My PRs")
        .toolbar {
            // In-tab fallback refresh button. The tab also responds to the
            // global toolbar's `refreshTick` once SidebarView wires it up.
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh My PRs", systemImage: "arrow.clockwise.circle")
                }
                .help("Refresh My PRs")
            }
        }
        .onChange(of: refreshTick) { _, _ in
            Task { await refresh() }
        }
        .task {
            if !vm.hasFetchedOnce && !vm.isLoading {
                await refresh()
            }
        }
        .sheet(isPresented: $showReauthSheet) {
            TokenPromptSheet(reason: .reauth) {
                showReauthSheet = false
                Task { await refresh() }
            }
        }
    }

    // MARK: - Stats bar

    @ViewBuilder
    private var statsBar: some View {
        if vm.hasFetchedOnce && !vm.rows.isEmpty {
            let withApprovals = vm.rows.filter { $0.reviewState.reviewers.contains { $0.status == .approved } }.count
            let changesReq = vm.rows.filter { $0.reviewState.reviewers.contains { $0.status == .changesRequested } }.count
            let awaitingReply = vm.rows.filter { $0.reviewState.unresolved.awaitingYou > 0 }.count
            let drafts = vm.rows.filter { $0.pr.draft }.count

            HStack(spacing: 12) {
                StatChip(dotColor: .green, value: withApprovals, label: "with approvals")
                StatChip(dotColor: .red, value: changesReq, label: "changes requested")
                if awaitingReply > 0 {
                    StatChip(dotColor: .orange, value: awaitingReply, label: "awaiting your reply")
                }
                if drafts > 0 {
                    StatChip(dotColor: .gray, value: drafts, label: "drafts")
                }
                StatChip(dotColor: nil, value: vm.rows.count, label: "total")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.05))
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.rows.isEmpty {
            ProgressView("Loading authored PRs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !vm.hasFetchedOnce {
            EmptyHint(text: "Loading your authored PRs…")
        } else if vm.rows.isEmpty {
            EmptyHint(text: "No open PRs authored by you.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(vm.rows) { row in
                        MyPRCard(row: row)
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Refresh

    @MainActor
    private func refresh() async {
        vm.isLoading = true
        vm.errorMessage = nil
        defer { vm.isLoading = false }
        do {
            // 1. Resolve viewer login (cache once).
            let login: String
            if let cached = vm.currentUser {
                login = cached
            } else {
                login = try await client.fetchCurrentUserLogin()
                vm.currentUser = login
            }

            // 2. Authored PRs.
            let prs = try await client.fetchAuthoredPRs()

            // 3. Fan-out for review state. Failures per-PR degrade to .empty so
            //    one bad PR does not blank the whole list (matches index.html).
            let assembled = await withTaskGroup(of: (Int, MyPRRow).self) { group in
                for (index, pr) in prs.enumerated() {
                    group.addTask {
                        let state: PRReviewState
                        do {
                            state = try await client.fetchPRReviewState(
                                repo: pr.repoFullName,
                                number: pr.number,
                                currentUser: login
                            )
                        } catch {
                            state = .empty
                        }
                        return (index, MyPRRow(pr: pr, reviewState: state))
                    }
                }
                var collected: [(Int, MyPRRow)] = []
                for await result in group {
                    collected.append(result)
                }
                return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
            }

            vm.rows = assembled
            vm.hasFetchedOnce = true
        } catch GitHubError.unauthorized {
            vm.errorMessage = "GitHub returned 401. Please re-enter your token."
            vm.rows = []
            showReauthSheet = true
        } catch GitHubError.missingToken {
            vm.errorMessage = "No GitHub token stored. Add one to continue."
            showReauthSheet = true
        } catch GitHubError.http(let status, _) {
            vm.errorMessage = "GitHub error \(status)."
        } catch GitHubError.decoding(let detail) {
            vm.errorMessage = "Failed to decode GitHub response: \(detail)"
        } catch GitHubError.transport(let detail) {
            vm.errorMessage = "Network error: \(detail)"
        } catch {
            vm.errorMessage = "Unexpected error: \(error.localizedDescription)"
        }
    }
}

// MARK: - View model

struct MyPRRow: Identifiable, Hashable {
    let pr: AuthoredPR
    let reviewState: PRReviewState

    var id: Int { pr.id }
}

// MARK: - Card

private struct MyPRCard: View {
    let row: MyPRRow

    var body: some View {
        let pr = row.pr
        let state = row.reviewState

        Link(destination: pr.htmlURL) {
            VStack(alignment: .leading, spacing: 8) {
                // Top row: repo + draft + age
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.18)))
                    Spacer()
                    if pr.draft {
                        Text("Draft")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.gray.opacity(0.25)))
                            .foregroundStyle(.secondary)
                    }
                    Text(timeAgo(pr.createdAt))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Title + number
                Text("#\(pr.number)  \(pr.title)")
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Reviewer badges
                if !state.reviewers.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(state.reviewers) { reviewer in
                            ReviewerBadge(reviewer: reviewer)
                        }
                    }
                }

                // Bottom meta row: approvals, threads, comment count.
                HStack(spacing: 12) {
                    if !state.reviewers.isEmpty {
                        let approved = state.reviewers.filter { $0.status == .approved }.count
                        Text("\(approved)/\(state.reviewers.count) approved")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No reviewers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if state.unresolved.awaitingYou > 0 {
                        Label("\(state.unresolved.awaitingYou) awaiting you",
                              systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if state.totalThreads > 0 {
                        Label("All resolved", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }

                    if state.unresolved.awaitingOthers > 0 {
                        Label("\(state.unresolved.awaitingOthers) replied",
                              systemImage: "arrowshape.turn.up.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if state.totalComments > 0 {
                        Label("\(state.totalComments)", systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(cardBackground(for: row))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(cardStroke(for: row), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func cardBackground(for row: MyPRRow) -> Color {
        if row.pr.draft { return Color.gray.opacity(0.06) }
        let reviewers = row.reviewState.reviewers
        if reviewers.contains(where: { $0.status == .changesRequested }) {
            return Color.red.opacity(0.06)
        }
        if row.reviewState.unresolved.awaitingYou > 0 {
            return Color.orange.opacity(0.06)
        }
        if !reviewers.isEmpty && reviewers.allSatisfy({ $0.status == .approved }) {
            return Color.green.opacity(0.06)
        }
        return Color.gray.opacity(0.06)
    }

    private func cardStroke(for row: MyPRRow) -> Color {
        if row.pr.draft { return Color.gray.opacity(0.18) }
        let reviewers = row.reviewState.reviewers
        if reviewers.contains(where: { $0.status == .changesRequested }) {
            return Color.red.opacity(0.35)
        }
        if row.reviewState.unresolved.awaitingYou > 0 {
            return Color.orange.opacity(0.35)
        }
        if !reviewers.isEmpty && reviewers.allSatisfy({ $0.status == .approved }) {
            return Color.green.opacity(0.35)
        }
        return Color.gray.opacity(0.18)
    }

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
}

// MARK: - Reviewer badge

private struct ReviewerBadge: View {
    let reviewer: ReviewerEntry

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(reviewer.login)
                .font(.caption2)
            if reviewer.reRequested {
                Text("↻")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.gray.opacity(0.12)))
        .help(tooltip)
    }

    private var dotColor: Color {
        switch reviewer.status {
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .blue
        case .dismissed: return .gray
        case .pending: return .yellow
        case .reRequested: return .orange
        }
    }

    private var tooltip: String {
        let base = "\(reviewer.login): \(reviewer.status.label)"
        return reviewer.reRequested ? "\(base) · re-review requested" : base
    }
}

// MARK: - Stats chip

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

// MARK: - Empty / error helpers (private to this tab — duplicating slice 01's
// versions on purpose; the slice 01 ones are also private-to-file).

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
