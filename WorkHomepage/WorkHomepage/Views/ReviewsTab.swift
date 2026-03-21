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

// swiftlint:disable file_length

struct ReviewsTab: View {
    /// Persistent data container owned by SidebarView. Keeping the loaded
    /// pending/reviewed PRs here means tab switches don't clear the list.
    @Bindable var vm: ReviewsViewModel
    /// Bumped by SidebarView's toolbar Refresh button. Defaulted so the tab
    /// can be constructed in previews.
    var refreshTick: Int = 0

    // MARK: - Persisted filter state

    /// "Hide PRs with >= N approvals". Default 2 (matches index.html).
    @AppStorage("reviews.approvalThreshold") private var approvalThreshold: Int = 2
    /// "Show my dismissed reviews" toggle. Default off.
    @AppStorage("reviews.showDismissed") private var showDismissed: Bool = false

    // MARK: - Transient UI state (does not need to survive tab switches)

    @State private var showReauthSheet: Bool = false

    /// True when the review modal should be presented. The modal is
    /// orchestrator-driven (slice/07-fix); we just toggle the binding.
    @State private var showReviewSheet: Bool = false
    /// Surfaces transient errors from the Review button (branch fetch failure,
    /// single-flight rejection). Cleared on next attempt.
    @State private var reviewError: String?

    /// Slice 15 — transient banner shown after the closed-PR sweep or a manual
    /// evict. Auto-dismisses after 3s. Nil when nothing to show.
    @State private var cleanupNotice: String?
    /// Slice 15 — confirmation alert state for the per-card "Evict review
    /// state" context-menu item.
    @State private var pendingManualEvict: PendingManualEvict?
    /// Slice 15 — error alert when a manual evict is refused (running review).
    @State private var manualEvictError: String?

    /// Singleton orchestrator state, observed so the Review button on each
    /// card can disable itself while another review is running and so the
    /// modal sheet can pull live state.
    @State private var orchestrator = ReviewOrchestrator.shared
    /// SwiftData context borrowed for the orchestrator's `ReviewStore`. We
    /// pull it from the environment in `body` and cache it the first time
    /// `startReview` runs.
    @Environment(\.modelContext) private var modelContext

    private let client = GitHubClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage = vm.errorMessage {
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
        .task {
            // Auto-fetch the first time the tab is shown. The vm survives
            // tab switches, so subsequent appearances skip the fetch and
            // just re-display the cached PRs.
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
        .sheet(isPresented: $showReviewSheet) {
            ReviewSheet(
                orchestrator: orchestrator,
                onReReview: { review in reReview(review) }
            )
        }
        .overlay(alignment: .top) {
            if let cleanupNotice {
                CleanupToast(text: cleanupNotice)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .alert(
            "Evict cached review state?",
            isPresented: Binding(
                get: { pendingManualEvict != nil },
                set: { if !$0 { pendingManualEvict = nil } }
            ),
            presenting: pendingManualEvict
        ) { evict in
            Button("Evict", role: .destructive) {
                performManualEvict(evict)
                pendingManualEvict = nil
            }
            Button("Cancel", role: .cancel) {
                pendingManualEvict = nil
            }
        } message: { evict in
            Text("Evict cached review state for \(evict.prKey)? Bare clone is preserved.")
        }
        .alert(
            "Cannot evict",
            isPresented: Binding(
                get: { manualEvictError != nil },
                set: { if !$0 { manualEvictError = nil } }
            ),
            presenting: manualEvictError
        ) { _ in
            Button("OK", role: .cancel) { manualEvictError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Slice 15 — manual evict plumbing

    /// Captures the data needed by the confirmation alert. Must be Identifiable
    /// for `.alert(presenting:)`.
    fileprivate struct PendingManualEvict: Identifiable {
        let id = UUID()
        let repo: String
        let prNumber: Int
        var prKey: String { "\(repo)#\(prNumber)" }
    }

    /// Called by the per-card context menu. Refuses immediately if the
    /// orchestrator currently has a running review against this exact PR;
    /// otherwise stages the alert.
    @MainActor
    fileprivate func requestManualEvict(repo: String, prNumber: Int) {
        let prKey = "\(repo)#\(prNumber)"
        if orchestrator.running.contains(where: { $0.prKey == prKey }) {
            manualEvictError = "A review is currently running for \(prKey). Wait for it to finish before evicting."
            return
        }
        pendingManualEvict = PendingManualEvict(repo: repo, prNumber: prNumber)
    }

    /// Confirmed path. Runs the same evict + drop the auto-cleanup uses, then
    /// surfaces a toast.
    @MainActor
    fileprivate func performManualEvict(_ evict: PendingManualEvict) {
        // Re-check at confirm time — the user could have started a review
        // between opening the menu and confirming.
        if orchestrator.running.contains(where: { $0.prKey == evict.prKey }) {
            manualEvictError = "A review is currently running for \(evict.prKey). Wait for it to finish before evicting."
            return
        }
        do {
            try WorktreeManager.evict(repo: evict.repo, prNumber: evict.prNumber)
        } catch {
            // Tolerate evict failure — still drop the rows. Bare clone is
            // untouched either way; the user can retry from the disk-usage
            // screen (slice 17) if the worktree dir is wedged.
        }
        let store = ReviewStore(context: modelContext)
        store.dropForPR(prKey: evict.prKey)
        showCleanupNotice("Evicted review state for \(evict.prKey)")
    }

    /// Posts a transient toast and schedules its dismissal. New posts cancel
    /// any in-flight dismissal by overwriting the @State.
    @MainActor
    fileprivate func showCleanupNotice(_ text: String) {
        cleanupNotice = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Only clear if this is still the same notice — a later post
            // would have overwritten the string already.
            if cleanupNotice == text {
                cleanupNotice = nil
            }
        }
    }

    // MARK: - Review button plumbing

    /// Resolves head branch + SHA via REST, then either:
    ///   - opens the modal on the existing `(prKey, headSha)` row when one
    ///     exists in `completed` state and `force` is false (slice 14
    ///     dedupe), or
    ///   - kicks off a fresh orchestrator run otherwise.
    ///
    /// Surfaces failures via `reviewError`. The orchestrator (slice 13)
    /// accepts multiple in-flight reviews up to the configured concurrency
    /// cap and queues anything beyond that.
    ///
    /// `force` is true when the user clicks "Re-review" inside the modal —
    /// that path always inserts a new Review row even if one already exists
    /// for the current sha.
    @MainActor
    fileprivate func startReview(
        repo: String,
        prNumber: Int,
        prTitle: String,
        force: Bool = false
    ) async {
        reviewError = nil
        do {
            let info = try await client.fetchPRBranchInfo(repo: repo, number: prNumber)
            let store = ReviewStore(context: modelContext)
            let prKey = "\(repo)#\(prNumber)"
            let existing = store.latestForPRAtSha(prKey: prKey, headSha: info.headSha)
            if ReviewVersioning.shouldStartNewRun(existingForSha: existing, force: force) {
                await orchestrator.start(
                    repo: repo,
                    prNumber: prNumber,
                    branch: info.headBranch,
                    sha: info.headSha,
                    store: store
                )
            } else if let existing {
                // Reuse: surface the existing row in the modal without
                // spawning anything. The modal binds to `orchestrator.current`,
                // so we point it at the persisted row.
                orchestrator.current = existing
            }
            showReviewSheet = true
        } catch {
            reviewError = "Could not fetch PR branch info: \(error)"
        }
    }

    /// Closure handed to the modal's "Re-review" button. The modal stays
    /// orchestrator-agnostic for the start path; this view owns it and re-
    /// uses `startReview(force: true)`. We extract repo / prNumber / title
    /// from the displayed Review so the user doesn't have to be on the right
    /// PR card when they click.
    @MainActor
    fileprivate func reReview(_ review: Review) {
        Task {
            await startReview(
                repo: review.repoFullName,
                prNumber: review.prNumber,
                prTitle: "",
                force: true
            )
        }
    }

    // MARK: - Slice 13 — pending lookup

    /// Returns the orchestrator's row for `prKey` if it's currently queued or
    /// running, otherwise nil. Drives the per-card Review button's state.
    @MainActor
    fileprivate func pendingForPR(_ prKey: String) -> Review? {
        if let r = orchestrator.running.first(where: { $0.prKey == prKey }) { return r }
        if let r = orchestrator.queued.first(where: { $0.prKey == prKey }) { return r }
        return nil
    }

    /// Position of `review` among queued reviews (0-based). Used to render
    /// "Queued (N ahead)". The first queued review is "Queued (0 ahead)".
    @MainActor
    fileprivate func queuePosition(of review: Review) -> Int {
        orchestrator.queued.firstIndex(where: { $0.id == review.id }) ?? 0
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
        .background(Color.bgSurface)
    }

    // MARK: - Stats bar

    @ViewBuilder
    private var statsBar: some View {
        if vm.hasFetchedOnce {
            let derived = derivedStats()
            HStack(spacing: 12) {
                StatChip(dotColor: .accentMarigold, value: derived.awaiting, label: "awaiting")
                StatChip(dotColor: .accentFern, value: derived.withApprovals, label: "with approvals")
                if derived.drafts > 0 {
                    StatChip(dotColor: .accentGray, value: derived.drafts, label: "drafts")
                }
                if showDismissed && derived.dismissed > 0 {
                    StatChip(dotColor: .accentTerracotta, value: derived.dismissed, label: "dismissed")
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
            .background(Color.bgSurface)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.pendingPRs.isEmpty && vm.reviewedPRs.isEmpty {
            ProgressView("Loading reviews…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !vm.hasFetchedOnce {
            EmptyHint(text: "Loading review-requested PRs…")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    pendingSection
                    reviewedSubSections
                }
                .padding()
            }
            .background(Color.bgDeep)
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
                if let reviewError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.accentTerracotta)
                        Text(reviewError)
                            .font(Font.appBody(size: 11))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentTerracotta.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                ForEach(visible) { pr in
                    HStack(alignment: .top, spacing: 8) {
                        PendingPRCard(pr: pr)
                        VStack(alignment: .trailing, spacing: 4) {
                            reviewButton(
                                for: pr.repoFullName,
                                prNumber: pr.number,
                                prTitle: pr.title
                            )
                            latestVerdictBadge(repo: pr.repoFullName, prNumber: pr.number)
                        }
                    }
                    .contextMenu {
                        Button("Evict review state") {
                            requestManualEvict(repo: pr.repoFullName, prNumber: pr.number)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var reviewedSubSections: some View {
        let pendingIds = Set(vm.pendingPRs.map(\.id))
        let reviewed = vm.reviewedPRs.filter { !pendingIds.contains($0.id) }
        let changesReq = reviewed.filter { $0.myLastReviewState == .changesRequested }
        let commented = reviewed.filter { $0.myLastReviewState == .commented }
        let approved = reviewed.filter { $0.myLastReviewState == .approved }

        if !changesReq.isEmpty {
            SubSection(title: "Changes Requested", count: changesReq.count, accent: .accentTerracotta) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(changesReq) { pr in
                        reviewedRow(pr: pr)
                    }
                }
            }
        }
        if !commented.isEmpty {
            SubSection(title: "My Comments", count: commented.count, accent: .accentMarigold) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(commented) { pr in
                        reviewedRow(pr: pr)
                    }
                }
            }
        }
        if !approved.isEmpty {
            SubSection(title: "Already Approved", count: approved.count, accent: .accentFern) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(approved) { pr in
                        reviewedRow(pr: pr)
                    }
                }
            }
        }
    }

    /// Row used in each "reviewed-by:@me" sub-section. Card on the left,
    /// Review button on the right — same layout as the pending row, but the
    /// PR identity comes from `ReviewedPR` instead of `PendingReviewPR`.
    @ViewBuilder
    fileprivate func reviewedRow(pr: ReviewedPR) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ReviewedPRCard(pr: pr)
            VStack(alignment: .trailing, spacing: 4) {
                reviewButton(
                    for: pr.repoFullName,
                    prNumber: pr.number,
                    prTitle: pr.title
                )
                latestVerdictBadge(repo: pr.repoFullName, prNumber: pr.number)
            }
        }
        .contextMenu {
            Button("Evict review state") {
                requestManualEvict(repo: pr.repoFullName, prNumber: pr.number)
            }
        }
    }

    // MARK: - Slice 14 — latest-verdict adornment

    /// Small badge shown under the per-card Review button when at least one
    /// prior Review row exists for the PR. Independent of the slice 13
    /// button-state machine: the button reflects in-flight state, the badge
    /// reflects the most recently *completed* verdict.
    @ViewBuilder
    fileprivate func latestVerdictBadge(repo: String, prNumber: Int) -> some View {
        let prKey = "\(repo)#\(prNumber)"
        let store = ReviewStore(context: modelContext)
        if let latest = store.latestForPR(prKey: prKey) {
            Button {
                // Open the existing review in the modal without spawning a
                // new run. The modal binds to `orchestrator.current`.
                orchestrator.current = latest
                showReviewSheet = true
            } label: {
                LatestVerdictBadge(review: latest)
            }
            .buttonStyle(.plain)
            .help("Open this review")
        }
    }

    // MARK: - Slice 13 — per-card review button factory

    /// Resolves the per-PR `ReviewButton.Mode` from orchestrator state.
    /// Pulled out of the view builder so the `if let` / `switch` ladder
    /// doesn't trip the ViewBuilder result-builder.
    @MainActor
    fileprivate func reviewButtonMode(for prKey: String) -> ReviewButton.Mode {
        guard let p = pendingForPR(prKey) else { return .start }
        switch p.state {
        case "queued":  return .queued(ahead: queuePosition(of: p))
        case "running": return .running
        default:        return .start
        }
    }

    /// Builds the right-hand Review button for a PR row. Delegates to
    /// `ReviewButton`, which renders one of four states based on whether the
    /// orchestrator currently has a queued/running entry for this PR.
    @ViewBuilder
    fileprivate func reviewButton(for repo: String, prNumber: Int, prTitle: String) -> some View {
        let prKey = "\(repo)#\(prNumber)"
        let mode = reviewButtonMode(for: prKey)
        ReviewButton(mode: mode) {
            switch mode {
            case .start:
                Task {
                    await startReview(repo: repo, prNumber: prNumber, prTitle: prTitle)
                }
            case .queued, .running:
                if let p = pendingForPR(prKey) {
                    orchestrator.cancel(p)
                }
            }
        }
    }

    // MARK: - Filter / stats derivations

    private func visiblePendingPRs() -> [PendingReviewPR] {
        var visible = vm.pendingPRs.filter {
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
        let withApp = vm.pendingPRs.filter { $0.approvalCount > 0 }.count
        let drafts = vm.pendingPRs.filter { $0.isDraft }.count
        let dismissed = vm.pendingPRs.filter { $0.isDismissed }.count
        let awaiting = max(0, vm.pendingPRs.count - withApp - drafts)
        let visible = visiblePendingPRs()
        let total = vm.pendingPRs.count
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

            // 2. Fan-out the two searches in parallel.
            async let pending = client.fetchPendingReviewPRs(currentUser: login)
            async let reviewed = client.fetchReviewedByMePRs(currentUser: login)
            let (p, r) = try await (pending, reviewed)
            vm.pendingPRs = p
            vm.reviewedPRs = r
            vm.hasFetchedOnce = true

            // 3. Slice 15 — sweep tracked PRs that no longer appear in either
            // open-PR set. `prKey` shape matches what `ReviewOrchestrator`
            // writes ("<org>/<repo>#<number>").
            var openKeys: Set<String> = []
            openKeys.reserveCapacity(p.count + r.count)
            for pr in p { openKeys.insert("\(pr.repoFullName)#\(pr.number)") }
            for pr in r { openKeys.insert("\(pr.repoFullName)#\(pr.number)") }
            let store = ReviewStore(context: modelContext)
            let detector = ClosedPRDetector(store: store)
            let cleaned = detector.cleanupClosedPRs(openPRKeys: openKeys)
            if cleaned > 0 {
                showCleanupNotice("Cleaned up \(cleaned) closed PR\(cleaned == 1 ? "" : "s")")
            }
        } catch GitHubError.unauthorized {
            vm.errorMessage = "GitHub returned 401. Please re-enter your token."
            vm.pendingPRs = []
            vm.reviewedPRs = []
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

// MARK: - Pending PR card

private struct PendingPRCard: View {
    let pr: PendingReviewPR

    var body: some View {
        Link(destination: pr.htmlURL) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.borderSubtle))
                    Spacer()
                    if pr.isDismissed {
                        TagPill(text: "Dismissed", color: .accentTerracotta)
                    }
                    if pr.isDraft {
                        TagPill(text: "Draft", color: .accentGray)
                    }
                    if let prior = pr.myPriorReviewState, !pr.isDismissed {
                        ReReviewTag(state: prior)
                    }
                    Text(timeAgo(pr.createdAt))
                        .font(Font.appBody(size: 11))
                        .foregroundStyle(Color.textMuted)
                }
                Text("#\(pr.number)  \(pr.title)")
                    .font(Font.display(size: 14))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ReviewerAvatarView(
                            login: pr.authorLogin,
                            avatarURL: nil,
                            role: .author,
                            size: 24
                        )
                        Text("@\(pr.authorLogin)")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    if pr.approvalCount == 0 && pr.changesRequestedCount == 0 {
                        Text("No approvals")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textMuted)
                    } else {
                        if pr.approvalCount > 0 {
                            Label("\(pr.approvalCount)", systemImage: "checkmark")
                                .font(Font.appBody(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentFern)
                        }
                        if pr.changesRequestedCount > 0 {
                            Label("\(pr.changesRequestedCount)", systemImage: "xmark")
                                .font(Font.appBody(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentTerracotta)
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
        if pr.isDismissed { return Color.accentTerracotta.opacity(0.06) }
        if pr.changesRequestedCount > 0 { return Color.accentTerracotta.opacity(0.05) }
        if pr.approvalCount > 0 { return Color.accentFern.opacity(0.05) }
        if pr.isDraft { return Color.accentGray.opacity(0.05) }
        return Color.bgCard
    }

    private var cardStroke: Color {
        if pr.isDismissed { return Color.accentTerracotta.opacity(0.40) }
        if pr.changesRequestedCount > 0 { return Color.accentTerracotta.opacity(0.30) }
        if pr.approvalCount > 0 { return Color.accentFern.opacity(0.30) }
        return Color.borderSubtle
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
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.borderSubtle))
                    Spacer()
                    ReReviewTag(state: pr.myLastReviewState)
                    Text(timeAgo(pr.createdAt))
                        .font(Font.appBody(size: 11))
                        .foregroundStyle(Color.textMuted)
                }
                Text("#\(pr.number)  \(pr.title)")
                    .font(Font.display(size: 14))
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .foregroundStyle(Color.textPrimary)
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ReviewerAvatarView(
                            login: pr.authorLogin,
                            avatarURL: nil,
                            role: .author,
                            size: 24
                        )
                        Text("@\(pr.authorLogin)")
                            .font(Font.appBody(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    if pr.approvalCount > 0 {
                        Label("\(pr.approvalCount)", systemImage: "checkmark")
                            .font(Font.appBody(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentFern)
                    }
                    if pr.changesRequestedCount > 0 {
                        Label("\(pr.changesRequestedCount)", systemImage: "xmark")
                            .font(Font.appBody(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentTerracotta)
                    }
                }
                if pr.newCommitsSinceReview > 0 {
                    NewCommitsBadge(count: pr.newCommitsSinceReview)
                } else if pr.myLastReviewSubmittedAt != nil {
                    Text("No changes since your review")
                        .font(Font.appBody(size: 11))
                        .foregroundStyle(Color.textSecondary)
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
        case .changesRequested: return Color.accentTerracotta.opacity(0.05)
        case .approved:         return Color.accentFern.opacity(0.05)
        case .commented:        return Color.accentMarigold.opacity(0.04)
        default:                return Color.bgCard
        }
    }

    private var cardStroke: Color {
        switch pr.myLastReviewState {
        case .changesRequested: return Color.accentTerracotta.opacity(0.30)
        case .approved:         return Color.accentFern.opacity(0.30)
        case .commented:        return Color.accentMarigold.opacity(0.30)
        default:                return Color.borderSubtle
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
        case .approved:          return .accentFern
        case .changesRequested:  return .accentTerracotta
        case .commented:         return .accentMarigold
        case .dismissed:         return .accentTerracotta
        case .pending:           return .accentGray
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
                .font(Font.appBody(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentMarigold.opacity(0.18)))
        .foregroundStyle(Color.accentMarigold)
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
                .foregroundStyle(Color.accentTerracotta)
            Text(message)
                .font(Font.appBody(size: 13))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentTerracotta.opacity(0.12))
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

// MARK: - Cleanup toast (slice 15)

/// Transient banner used by the closed-PR sweep and the per-card manual
/// evict. Auto-dismisses after 3s — the parent view owns the timer.
private struct CleanupToast: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(.callout.weight(.medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }
}

// MARK: - Review button (slice 13)

/// Trigger button on each PR row. Three modes mapped to the orchestrator's
/// per-PR state:
///   - `.start`               → "Review", borderedProminent, click starts a run
///   - `.queued(ahead: N)`    → "Queued (N ahead)", click cancels (removes
///                             from queue, never spawns)
///   - `.running`             → "Running…" with a spinner, click cancels
///                             (SIGTERM/SIGKILL the process)
///
/// Slice 14 will add a "Re-review" mode for terminated states; for now the
/// per-card button stays at `.start` once the orchestrator has dropped the
/// review out of running/queued, which is fine because the existing modal
/// surfaces past results.
private struct ReviewButton: View {
    enum Mode: Equatable {
        case start
        case queued(ahead: Int)
        case running
    }

    let mode: Mode
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            label
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .help(helpText)
    }

    @ViewBuilder
    private var label: some View {
        switch mode {
        case .start:
            Label("Review", systemImage: "wand.and.stars")
        case .queued(let ahead):
            Label("Queued (\(ahead) ahead)", systemImage: "clock")
        case .running:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white)
                Text("Running…")
            }
        }
    }

    private var helpText: String {
        switch mode {
        case .start:
            return "Run a Claude review on this PR."
        case .queued(let ahead):
            return "Queued (\(ahead) ahead). Click to cancel."
        case .running:
            return "Review in progress. Click to cancel."
        }
    }
}

// MARK: - Latest verdict badge (slice 14)

/// Surfaces the most recent Review row's verdict / state on the PR card.
/// Independent of the slice 13 in-flight button-state machine — this is a
/// pure read of `ReviewStore.latestForPR`. We bind on `Review` so SwiftData
/// observation re-renders the badge if the row's state or verdict mutates
/// while the tab is open (e.g. a running review terminates).
private struct LatestVerdictBadge: View {
    @Bindable var review: Review

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
        .foregroundStyle(color)
        .help(tooltip)
    }

    private var label: String {
        // Terminal-but-no-verdict states get their own label so the user
        // knows why they're not seeing approve/changes/comment.
        switch review.state {
        case "running":   return "running"
        case "queued":    return "queued"
        case "failed":    return "failed"
        case "timeout":   return "timed out"
        case "cancelled": return "cancelled"
        default:
            switch (review.verdict ?? "").lowercased() {
            case "approve":         return "approve"
            case "request_changes": return "changes"
            case "comment":         return "comment"
            default:                return "no verdict"
            }
        }
    }

    private var color: Color {
        switch review.state {
        case "running", "queued":      return .accentFern
        case "failed", "timeout":      return .accentMarigold
        case "cancelled":              return .accentGray
        default:
            switch (review.verdict ?? "").lowercased() {
            case "approve":         return .accentFern
            case "request_changes": return .accentTerracotta
            case "comment":         return .accentMarigold
            default:                return .accentGray
            }
        }
    }

    private var tooltip: String {
        let sha = String(review.headSha.prefix(7))
        return "Latest review for sha \(sha) — \(review.state)"
    }
}
