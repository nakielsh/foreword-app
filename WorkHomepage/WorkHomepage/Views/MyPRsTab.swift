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
    /// Holds the in-flight refresh Task so a new tick cancels the prior one
    /// (rapid refreshes otherwise overlap and last-writer-wins can clobber
    /// fresher data with stale results).
    @State private var refreshTask: Task<Void, Never>?

    private let client = GitHubClient()

    /// Cap on per-PR review-state fan-out. 8 in-flight GraphQL calls is a
    /// fair compromise: high enough to keep refreshes snappy on big PR lists,
    /// low enough that we don't hammer GitHub's secondary rate limits.
    private static let enrichmentConcurrency = 8

    /// Fetch one PR's review state and assemble a row. Pulled out of the
    /// task group body so the bounded-concurrency loop stays compact.
    private static func fetchRow(
        index: Int,
        pr: AuthoredPR,
        login: String,
        client: GitHubClient
    ) async -> (Int, MyPRRow) {
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
        let enrichedPR = AuthoredPR(
            id: pr.id,
            number: pr.number,
            title: pr.title,
            htmlURL: pr.htmlURL,
            user: pr.user,
            repositoryURL: pr.repositoryURL,
            draft: pr.draft,
            createdAt: pr.createdAt,
            branchRef: state.branchRef
        )
        return (index, MyPRRow(pr: enrichedPR, reviewState: state))
    }

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
                    startRefreshTask()
                } label: {
                    Label("Refresh My PRs", systemImage: "arrow.clockwise.circle")
                }
                .help("Refresh My PRs")
            }
        }
        .onChange(of: refreshTick) { _, _ in
            startRefreshTask()
        }
        .task {
            if !vm.hasFetchedOnce && !vm.isLoading {
                await refresh()
            }
        }
        .sheet(isPresented: $showReauthSheet) {
            TokenPromptSheet(reason: .reauth) {
                showReauthSheet = false
                startRefreshTask()
            }
        }
    }

    @MainActor
    private func startRefreshTask() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await refresh()
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
                StatChip(dotColor: .accentFern, value: withApprovals, label: "with approvals")
                StatChip(dotColor: .accentTerracotta, value: changesReq, label: "changes requested")
                if awaitingReply > 0 {
                    StatChip(dotColor: .accentMarigold, value: awaitingReply, label: "awaiting your reply")
                }
                if drafts > 0 {
                    StatChip(dotColor: .accentGray, value: drafts, label: "drafts")
                }
                StatChip(dotColor: nil, value: vm.rows.count, label: "total")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.bgSurface)
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
            .background(Color.bgDeep)
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
            //    `PRReviewState.branchRef` carries `headRefName` from the
            //    GraphQL payload (already requested by the query) — copy it into
            //    `AuthoredPR.branchRef` so `JiraBadgeView` can render on cards.
            //
            //    Bound the fan-out to `Self.enrichmentConcurrency` so a 30-PR
            //    refresh doesn't fire 30 concurrent GraphQL calls at once.
            let clientRef = client
            let assembled = await withTaskGroup(of: (Int, MyPRRow).self) { group in
                var nextIndex = 0
                let total = prs.count
                let cap = min(Self.enrichmentConcurrency, total)
                while nextIndex < cap {
                    let i = nextIndex
                    let pr = prs[i]
                    group.addTask {
                        await Self.fetchRow(
                            index: i,
                            pr: pr,
                            login: login,
                            client: clientRef
                        )
                    }
                    nextIndex += 1
                }
                var collected: [(Int, MyPRRow)] = []
                while let result = await group.next() {
                    collected.append(result)
                    if nextIndex < total {
                        let i = nextIndex
                        let pr = prs[i]
                        group.addTask {
                            await Self.fetchRow(
                                index: i,
                                pr: pr,
                                login: login,
                                client: clientRef
                            )
                        }
                        nextIndex += 1
                    }
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
                // Top row: repo + jira badge + draft + age
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.borderSubtle))
                    JiraBadgeView(branchName: pr.branchRef)
                    Spacer()
                    if pr.draft {
                        Text("Draft")
                            .font(Font.appBody(size: 10, weight: .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentGray.opacity(0.18)))
                            .foregroundStyle(Color.accentGray)
                    }
                    Text(timeAgo(pr.createdAt))
                        .font(Font.appBody(size: 11))
                        .foregroundStyle(Color.textMuted)
                }

                // Author avatar + title + number
                HStack(alignment: .center, spacing: 8) {
                    ReviewerAvatarView(
                        login: pr.user.login,
                        avatarURL: pr.user.avatarURL,
                        role: .author,
                        size: 24
                    )
                    Text("#\(pr.number)  \(pr.title)")
                        .font(Font.display(size: 14))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Color.textPrimary)
                }

                // Reviewer inline rows: [avatar] @login [status pill]
                if !state.reviewers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(state.reviewers) { reviewer in
                            ReviewerRow(reviewer: reviewer)
                        }
                    }
                }

                // Bottom meta row: approvals, threads, comment count.
                HStack(spacing: 12) {
                    if !state.reviewers.isEmpty {
                        let approved = state.reviewers.filter { $0.status == .approved }.count
                        Text("\(approved)/\(state.reviewers.count) approved")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    } else {
                        Text("No reviewers")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textMuted)
                    }

                    if state.unresolved.awaitingYou > 0 {
                        Label("\(state.unresolved.awaitingYou) awaiting you",
                              systemImage: "exclamationmark.circle")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.accentMarigold)
                    } else if state.totalThreads > 0 {
                        Label("All resolved", systemImage: "checkmark.circle")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.accentFern)
                    }

                    if state.unresolved.awaitingOthers > 0 {
                        Label("\(state.unresolved.awaitingOthers) replied",
                              systemImage: "arrowshape.turn.up.left")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    }

                    Spacer()

                    if state.totalComments > 0 {
                        Label("\(state.totalComments)", systemImage: "bubble.left")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textSecondary)
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
        if row.pr.draft { return Color.accentGray.opacity(0.05) }
        let reviewers = row.reviewState.reviewers
        if reviewers.contains(where: { $0.status == .changesRequested }) {
            return Color.accentTerracotta.opacity(0.05)
        }
        if row.reviewState.unresolved.awaitingYou > 0 {
            return Color.accentMarigold.opacity(0.05)
        }
        if !reviewers.isEmpty && reviewers.allSatisfy({ $0.status == .approved }) {
            return Color.accentFern.opacity(0.05)
        }
        return Color.bgCard
    }

    private func cardStroke(for row: MyPRRow) -> Color {
        if row.pr.draft { return Color.borderSubtle }
        let reviewers = row.reviewState.reviewers
        if reviewers.contains(where: { $0.status == .changesRequested }) {
            return Color.accentTerracotta.opacity(0.30)
        }
        if row.reviewState.unresolved.awaitingYou > 0 {
            return Color.accentMarigold.opacity(0.30)
        }
        if !reviewers.isEmpty && reviewers.allSatisfy({ $0.status == .approved }) {
            return Color.accentFern.opacity(0.30)
        }
        return Color.borderSubtle
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

// MARK: - Reviewer inline row: [avatar] @login [status pill]

private struct ReviewerRow: View {
    let reviewer: ReviewerEntry

    var body: some View {
        HStack(spacing: 6) {
            ReviewerAvatarView(
                login: reviewer.login,
                avatarURL: reviewer.avatarURL,
                role: .reviewer(status: reviewer.status),
                size: 24
            )
            Text("@\(reviewer.login)")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textSecondary)
            StatusPill(reviewer: reviewer)
        }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let reviewer: ReviewerEntry

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(reviewer.status.label)
                .font(Font.appBody(size: 10, weight: .semibold))
                .foregroundStyle(dotColor)
            if reviewer.reRequested {
                Text("↻")
                    .font(Font.appBody(size: 10, weight: .bold))
                    .foregroundStyle(Color.accentMarigold)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(dotColor.opacity(0.12)))
    }

    private var dotColor: Color {
        switch reviewer.status {
        case .approved:          return .accentFern
        case .changesRequested:  return .accentTerracotta
        case .commented:         return .accentGray
        case .dismissed:         return .accentGray
        case .pending:           return .accentMarigold
        case .reRequested:       return .accentMarigold
        }
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
                .font(Font.appBody(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Text(label)
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textSecondary)
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
                .font(Font.appBody(size: 15))
                .foregroundStyle(Color.textMuted)
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
                .foregroundStyle(Color.accentTerracotta)
            Text(message)
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentTerracotta.opacity(0.12))
    }
}
