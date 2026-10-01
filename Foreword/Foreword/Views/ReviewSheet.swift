//
//  ReviewSheet.swift
//  Foreword
//
//  Slice 08 — Findings UI.
//
//  Modal sheet showing whatever the orchestrator is currently working on (or
//  most recently finished). Replaces slice 07's raw-JSON dump with a styled
//  findings list. Layout (top to bottom):
//
//   - Header: PR identity strip + verdict badge + summary + (optional)
//     Jira-alignment notes block.
//   - While running: live stream view (the slice-07 monospaced ScrollView)
//     stays prominent so the user can watch claude think.
//   - On completion (with a decoded schema): filter bar (Show resolved /
//     Show dismissed toggles, both default-off, persisted via `@AppStorage`)
//     and a list of severity sections, each a `DisclosureGroup` defaulted
//     open, containing finding rows. The live stream collapses into a
//     "Stream log" disclosure at the bottom.
//   - On completion *with* a decode failure (the slice/07-fix path): a
//     warning banner, the raw JSON in a code block, and no findings list.
//   - On `failed` / `timeout`: error banner + the stream log.
//
//  The sheet does NOT own the lifecycle. Callers (per-card Review buttons in
//  ReviewsTab, the active-review pill in SidebarView) own `start()`. The
//  sheet is a pure observer of `orchestrator.current` — closing it never
//  cancels the run, and re-opening picks up wherever the run is now.
//
//  Finding state mutations route through `FindingStateStore` so the SwiftData
//  write + save lives outside SwiftUI body code.
//

import SwiftUI
import SwiftData
import struct Foundation.Date
import struct Foundation.AttributedString
import class Foundation.NotificationCenter

extension Notification.Name {
    /// Posted by `ReviewSheet` when the user clicks "Re-review" on a terminal
    /// review. `userInfo` carries `repo` (String) and `pr` (Int) so the
    /// observer (`ReviewsTab`) can dispatch a forced new run without holding a
    /// reference to the SwiftData object across windows.
    ///
    /// Replaces the old direct `onReReview` closure parameter — the sheet now
    /// lives in its own `Window` scene (so the parent window can be resized
    /// while the review is open) and can no longer carry a closure captured
    /// from the parent view.
    static let reReviewRequested = Notification.Name("foreword.reReviewRequested")
}

struct ReviewSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The same singleton instance ReviewsTab and SidebarView read from. The
    /// sheet's content derives from `orchestrator.current`; whenever the
    /// orchestrator transitions to a new run, the sheet (if open) follows
    /// automatically.
    @Bindable var orchestrator: ReviewOrchestrator

    /// Slice 14 — closure invoked when the user clicks "Re-review" on a
    /// terminated review. Optional so previews / tests can inject a stub.
    /// When nil (production use from the dedicated review window), the click
    /// posts `Notification.Name.reReviewRequested` instead — `ReviewsTab`
    /// observes it and runs `startReview(force: true)`. The sheet lives in a
    /// separate `Window` scene so it can no longer borrow a closure from the
    /// view that opened it; the notification is the cross-window bridge.
    var onReReview: ((Review) -> Void)? = nil

    /// Slice 14 — when set, the sheet renders this Review's persisted data
    /// instead of the live orchestrator state. Selected from the History
    /// disclosure; cleared via "Back to current". Finding state mutations
    /// still work because findings are persisted on each Review row.
    ///
    /// Stored as a `PersistentIdentifier`, not a direct `Review` reference:
    /// holding a SwiftData object across long-lived `@State` turns into a
    /// tombstone if the row is deleted (cascade from Review eviction, e.g.
    /// when ClosedPRDetector sweeps), and any subsequent property access
    /// crashes. Re-fetching by id is cheap and correct.
    @State private var historicalReviewID: PersistentIdentifier? = nil

    /// Filter toggles persist across launches per PRD Q8d so the user
    /// doesn't have to re-hide noise each time they open a review.
    @AppStorage("findings.showResolved") private var showResolved: Bool = false
    @AppStorage("findings.showDismissed") private var showDismissed: Bool = false

    /// Cached stores. Allocated once on first body invocation via
    /// `.task`/`.onAppear` rather than reconstructed per render. Both are
    /// `@MainActor` structs holding only a `ModelContext` reference, so this
    /// is a pure ergonomic / GC-pressure win — and avoids duplicating the
    /// SwiftData fetch path on every body invocation.
    @State private var reviewStore: ReviewStore?
    @State private var findingStateStore: FindingStateStore?

    /// Cached decoded `jira_alignment.notes` for the displayed review. Re-
    /// computed only when `rawResultJSON` changes via `.onChange`. Without
    /// this, `jiraAlignmentBlock` re-decodes the full `ReviewSchema` from
    /// the raw payload on every body invocation (ten times a second under
    /// streaming).
    @State private var cachedJiraNotes: String? = nil
    @State private var cachedJiraNotesSourceJSON: String? = nil

    /// Cached findings grouping. Recomputed only when the underlying findings
    /// list changes (count, ids, or filter toggles). `FindingsGrouper.group`
    /// allocates intermediate arrays per call; we previously paid that on
    /// every body invocation.
    @State private var cachedSections: [FindingsGrouper.Section] = []
    @State private var cachedSectionsKey: String = ""

    /// Throttled mirror of `review.partialStream` used to drive the live
    /// stream view. Updated at most ~30 times per second via a sampling task,
    /// not per claude-token, so the auto-scroll does not jitter when the
    /// model emits hundreds of tokens per second.
    @State private var throttledStream: String = ""

    // MARK: - Slice 09: launcher feedback
    //
    // A single piece of state captures the most recent launch outcome so the
    // sheet can surface the right affordance:
    //   - `.openedInIntelliJ`            → no UI feedback
    //   - `.openedWithoutLineJump`       → 3s auto-dismissing toast banner
    //   - `.fileMissing` / `.failed`     → modal alert with OK
    @State private var launcherToastMessage: String?
    @State private var launcherAlertMessage: String?

    /// Single source of truth for "which Review row is the body of this sheet
    /// rendering?". Either the user-selected historical row (re-fetched via
    /// its `PersistentIdentifier`), or the live orchestrator's `current`.
    /// Slice 14 indirection — slices 07-13 read `orchestrator.current`
    /// directly; we now route every read through this computed so toggling
    /// history is one line of state instead of a fork in every helper.
    private var displayedReview: Review? {
        if let id = historicalReviewID,
           let fetched = modelContext.registeredModel(for: id) as Review? {
            return fetched
        }
        return orchestrator.current
    }

    /// True iff the user is currently viewing a historical row (i.e. one
    /// other than the live `orchestrator.current`).
    private var isViewingHistorical: Bool {
        historicalReviewID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(Color.bgSurface)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                reReviewButtonIfNeeded
                cancelButtonIfNeeded
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            // Cache stores once per sheet presentation. Both wrap the live
            // model context; allocation is cheap but caching avoids
            // re-allocation on every body invocation, which mattered under
            // streaming.
            if reviewStore == nil {
                reviewStore = ReviewStore(context: modelContext)
            }
            if findingStateStore == nil {
                findingStateStore = FindingStateStore(context: modelContext)
            }
            // Seed the throttled stream mirror.
            if let r = displayedReview {
                throttledStream = r.partialStream
            }
        }
        // Sampling task — coalesces stream-buffer changes into ~30 Hz UI
        // updates. Avoids per-token `withAnimation` + scrollTo jitter.
        // Re-fires when the displayed review id changes (sheet swap or
        // history pivot).
        .task(id: displayedReview?.id) {
            guard let r = displayedReview else { return }
            // Initial sync.
            throttledStream = r.partialStream
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 33_000_000) // ~30 Hz
                if Task.isCancelled { break }
                let live = r.partialStream
                if live != throttledStream {
                    throttledStream = live
                }
                // Stop sampling once the run is terminal — there's nothing
                // more to coalesce, and we don't want to keep an idle timer
                // running while the sheet is parked on a completed review.
                if r.state != "running" {
                    break
                }
            }
        }
        .overlay(alignment: .top) {
            if let toast = launcherToastMessage {
                launcherToast(message: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        // Auto-dismiss the toast after 3s. `.task(id:)` is automatically
        // cancelled and re-fired whenever `launcherToastMessage` changes (new
        // toast, or sheet dismissed), so a stale timer can't clobber a fresh
        // toast or write to a dead view.
        .task(id: launcherToastMessage) {
            guard launcherToastMessage != nil else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                launcherToastMessage = nil
            }
        }
        .alert(
            "Could not open file",
            isPresented: Binding(
                get: { launcherAlertMessage != nil },
                set: { if !$0 { launcherAlertMessage = nil } }
            ),
            actions: {
                Button("OK", role: .cancel) { launcherAlertMessage = nil }
            },
            message: {
                Text(launcherAlertMessage ?? "")
            }
        )
    }

    // MARK: - Toast

    @ViewBuilder
    private func launcherToast(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentMarigold)
            Text(message)
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textPrimary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentMarigold.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 4)
    }

    // MARK: - Launcher dispatch

    /// Builds the worktree URL for the current review and launches IntelliJ
    /// at `file:line`. Maps `FallbackResult` cases onto toast / alert state
    /// so the body's overlays render the right feedback.
    private func handleFindingClick(finding: Finding) {
        guard let review = displayedReview else { return }
        let worktree = WorktreePath.url(
            for: review.repoFullName,
            prNumber: review.prNumber
        )
        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: finding.file,
            line: finding.line
        )
        switch result {
        case .openedInIntelliJ:
            // Success is silent — IntelliJ will surface itself.
            break
        case .openedWithoutLineJump:
            showToast("idea CLI not found — opened without line jump")
        case .fileMissing(let url):
            var message = "File not found in worktree: \(url.path)"
            if let hint = IntelliJLauncher.missingFileHint(worktree: worktree, file: finding.file) {
                message += "\n\n\(hint)"
            }
            launcherAlertMessage = message
        case .failed(let msg):
            launcherAlertMessage = "Could not open file: \(msg)"
        }
    }

    /// Shows a toast for ~3s, dismissing automatically. The auto-dismiss
    /// timer lives in a `.task(id: launcherToastMessage)` modifier on the
    /// view body, so showing a new toast cancels the old timer and re-fires
    /// against the new value — no risk of a stale closure clobbering a
    /// fresher message or writing to a dismissed view.
    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            launcherToastMessage = message
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(displayedReview?.repoFullName ?? "—")
                    .font(Font.appBody(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.borderSubtle))
                if let n = displayedReview?.prNumber {
                    Text("#\(n)")
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                JiraBadgeView(branchName: displayedReview?.headBranch)
                if isViewingHistorical {
                    historicalIndicator
                }
                Spacer()
                stateBadge
            }
            if let review = displayedReview {
                HStack(spacing: 8) {
                    // Author avatar — the Review model does not persist authorLogin or
                    // authorAvatarURL, so we use an empty login and nil URL; the
                    // MonogramRenderer shows a neutral placeholder circle.
                    ReviewerAvatarView(
                        login: "",
                        avatarURL: nil,
                        role: .author,
                        size: 24
                    )
                    Text("branch: \(review.headBranch)  ·  sha: \(review.headSha.prefix(8))")
                        .font(Font.mono(size: 11))
                        .foregroundStyle(Color.textMuted)
                        .textSelection(.enabled)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    verdictBadge(review: review)
                    if let summary = review.summary, !summary.isEmpty {
                        Text(summary)
                            .font(Font.display(size: 15))
                            .foregroundStyle(Color.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                jiraAlignmentBlock(review: review)
            }
        }
    }

    /// Pill rendered in the header strip while the user is viewing a
    /// historical Review row. Doubles as the "Back to current" affordance —
    /// clicking it clears `historicalReviewID` and the sheet snaps back to
    /// `orchestrator.current`. Hidden when the live orchestrator has nothing
    /// to fall back to (rare; would mean no current run at all).
    @ViewBuilder
    private var historicalIndicator: some View {
        Button {
            historicalReviewID = nil
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                Text("History")
                    .font(Font.appBody(size: 11, weight: .semibold))
                if orchestrator.current != nil {
                    Text("·")
                        .font(Font.appBody(size: 10))
                        .foregroundStyle(Color.textMuted)
                    Text("Back to current")
                        .font(Font.appBody(size: 10, weight: .semibold))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.accentGray.opacity(0.15)))
            .foregroundStyle(Color.textSecondary)
        }
        .buttonStyle(.plain)
        .help("Viewing a historical review. Click to return to the current run.")
    }

    @ViewBuilder
    private var stateBadge: some View {
        let state = displayedReview?.state ?? "idle"
        let (label, color): (String, Color) = {
            switch state {
            case "queued": return ("Queued", .accentGray)
            case "running": return ("Running", .accentFern)
            case "completed": return ("Completed", .accentFern)
            case "failed": return ("Failed", .accentTerracotta)
            case "timeout": return ("Timed out", .accentMarigold)
            case "cancelled": return ("Cancelled", .accentGray)
            default: return ("Idle", .accentGray)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(Font.appBody(size: 11, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Slice 13 cancel button. Visible only when the focused review is
    /// queued or running AND we're looking at the live row (not history —
    /// a historical row is by definition already terminal). Routes to
    /// `orchestrator.cancel(_:)`. Cancelling a queued review removes it from
    /// the queue (no spawn). Cancelling a running review SIGTERMs the
    /// underlying child and flips the row's state to `cancelled`.
    @ViewBuilder
    private var cancelButtonIfNeeded: some View {
        if !isViewingHistorical,
           let cur = orchestrator.current,
           cur.state == "running" || cur.state == "queued" {
            Button(role: .destructive) {
                orchestrator.cancel(cur)
            } label: {
                Label("Cancel review", systemImage: "stop.circle")
            }
            .help(cur.state == "queued"
                  ? "Remove this review from the queue."
                  : "Cancel the running review (SIGTERM, then SIGKILL after 2s if still alive).")
        }
    }

    /// Slice 14 — "Re-review" button. Visible when:
    ///   - the displayed review reached a terminal state (completed /
    ///     failed / timeout / cancelled), AND
    ///   - the orchestrator does not currently have a queued or running
    ///     review for this PR.
    /// Click → posts `.reReviewRequested` (production) or invokes the
    /// injected `onReReview` closure (tests / previews) — both end up running
    /// a fresh `startReview(force: true)` in `ReviewsTab`.
    @ViewBuilder
    private var reReviewButtonIfNeeded: some View {
        if let review = displayedReview,
           isTerminal(state: review.state),
           !orchestrator.running.contains(where: { $0.prKey == review.prKey }),
           !orchestrator.queued.contains(where: { $0.prKey == review.prKey }) {
            Button {
                if let onReReview {
                    onReReview(review)
                } else {
                    NotificationCenter.default.post(
                        name: .reReviewRequested,
                        object: nil,
                        userInfo: [
                            "repo": review.repoFullName,
                            "pr": review.prNumber
                        ]
                    )
                }
            } label: {
                Label("Re-review", systemImage: "arrow.clockwise")
            }
            .help("Run a fresh review against the current head SHA. Creates a new row; the old row is preserved.")
        }
    }

    /// Slice 14 — terminal-state predicate. Matches the orchestrator's
    /// state-machine vocabulary.
    private func isTerminal(state: String) -> Bool {
        switch state {
        case "completed", "failed", "timeout", "cancelled": return true
        default: return false
        }
    }

    /// Verdict capsule — colored per PRD Q4b: approve→fern, request_changes
    /// →terracotta, comment→marigold. Anything else (or nil) renders as a muted
    /// "No verdict" pill so the user still sees the slot.
    @ViewBuilder
    private func verdictBadge(review: Review) -> some View {
        let (label, color): (String, Color) = {
            switch (review.verdict ?? "").lowercased() {
            case "approve":         return ("Approve", Color.accentFern)
            case "request_changes": return ("Request changes", Color.accentTerracotta)
            case "comment":         return ("Comment", Color.accentMarigold)
            case "":                return ("No verdict", Color.accentGray)
            default:                return (review.verdict ?? "Unknown", Color.accentGray)
            }
        }()
        Text(label)
            .font(Font.appBody(size: 13, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.16)))
            .overlay(Capsule().stroke(color.opacity(0.4), lineWidth: 1))
    }

    /// Jira-alignment card — only renders when `jira_alignment.notes` is
    /// present. Slice 07 doesn't pipe Jira context into the prompt so this
    /// is usually nil; reading the notes back out of `Review` would mean
    /// re-decoding `rawResultJSON`, but slice 07 only stored `summary` and
    /// `verdict` on the model. We re-decode on demand to surface the notes.
    @ViewBuilder
    private func jiraAlignmentBlock(review: Review) -> some View {
        if let notes = jiraAlignmentNotes(for: review), !notes.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link")
                    .foregroundStyle(Color.textMuted)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jira alignment")
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textMuted)
                    Text(notes)
                        .font(Font.appBody(size: 13))
                        .foregroundStyle(Color.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.borderSubtle, lineWidth: 1)
            )
        }
    }

    /// Re-decode just the `jira_alignment.notes` out of the raw payload.
    /// Slice 07's `Review` model doesn't persist this field directly — only
    /// summary and verdict — so we lazily pull it from `rawResultJSON`.
    /// Result is memoised in `cachedJiraNotes`/`cachedJiraNotesSourceJSON`
    /// — re-decode only when the underlying JSON string actually changes.
    /// Profiling under streaming previously showed this running ten times
    /// a second on every body invocation.
    private func jiraAlignmentNotes(for review: Review) -> String? {
        let raw = review.rawResultJSON
        if cachedJiraNotesSourceJSON == raw {
            return cachedJiraNotes
        }
        // Recompute. Stash result + the source so subsequent reads short-
        // circuit. We mutate `@State` from a view-builder helper which is
        // safe under SwiftUI as long as we don't trigger a body re-eval
        // synchronously — `@State` setters from inside body do schedule a
        // re-eval, so we route through a small async hop.
        let decoded: String? = {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return (try? JSONDecoder().decode(ReviewSchema.self, from: data))?.jiraAlignment?.notes
        }()
        let captured = raw
        DispatchQueue.main.async {
            cachedJiraNotesSourceJSON = captured
            cachedJiraNotes = decoded
        }
        return decoded
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let rejection = orchestrator.lastRejection, displayedReview == nil {
            VStack {
                Spacer()
                Text(rejection)
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.accentMarigold)
                    .padding()
                Spacer()
            }
        } else if let review = displayedReview {
            switch review.state {
            case "queued":
                queuedContent(review: review)
            case "running":
                runningContent(review: review)
            case "completed":
                completedContent(review: review)
            case "failed", "timeout":
                terminalErrorContent(review: review)
            case "cancelled":
                cancelledContent(review: review)
            default:
                VStack {
                    Spacer()
                    ProgressView("Preparing review…")
                    Spacer()
                }
            }
        } else {
            VStack {
                Spacer()
                ProgressView("Preparing review…")
                Spacer()
            }
        }
    }

    /// While the run is in flight the stream takes the whole content area —
    /// findings haven't been parsed yet, so there's nothing else to show.
    @ViewBuilder
    private func runningContent(review: Review) -> some View {
        streamView(review: review)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Slice 13: queued — no stream yet, nothing to render. Show a spinner
    /// with a "Queued" label.
    @ViewBuilder
    private func queuedContent(review: Review) -> some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
            Text("Queued — waiting for a slot to open up.")
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Slice 13: cancelled — show whatever stream we accumulated before the
    /// SIGTERM and a "Cancelled" badge. We deliberately do NOT show
    /// findings: the cancellation contract drops them.
    @ViewBuilder
    private func cancelledContent(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(Color.accentGray)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cancelled")
                        .font(Font.appBody(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(review.errorMessage ?? "Review was cancelled.")
                        .font(Font.appBody(size: 11))
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
            }
            .padding()
            .background(Color.bgSurface)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                historyDisclosure(review: review)
                streamLogDisclosure(review: review)
            }
            .padding()
        }
    }

    /// Completion has two sub-shapes: schema-decoded (render findings) or
    /// schema-decode-failed (slice/07-fix fallback — show the warning + raw
    /// JSON). We distinguish on `errorMessage`, which `ReviewStore.markCompleted`
    /// only sets in the decode-failure path.
    @ViewBuilder
    private func completedContent(review: Review) -> some View {
        if let msg = review.errorMessage, !msg.isEmpty {
            schemaDecodeFailureContent(review: review, message: msg)
        } else {
            findingsContent(review: review)
        }
    }

    /// The happy path: filter bar, severity sections, then the stream log
    /// collapsed at the bottom. When `review.filterNotice` is set, a soft
    /// warning banner renders above the filter bar — distinct from the
    /// `errorMessage` (decode-failed) path which would have routed us into
    /// `schemaDecodeFailureContent` already.
    @ViewBuilder
    private func findingsContent(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice = review.filterNotice, !notice.isEmpty {
                filterNoticeBanner(notice)
            }

            filterBar(review: review)
                .padding(.horizontal)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let visible = filteredFindings(review: review)
                    if visible.isEmpty {
                        emptyFindingsMessage(review: review)
                    } else {
                        // Use cached sections — recomputed via `.onChange`
                        // only when the input set changes, so streaming
                        // updates don't re-bucket on every body invocation.
                        let sections = sectionsFor(visible: visible, review: review)
                        ForEach(sections, id: \.severity) { section in
                            severitySection(section: section)
                        }
                    }

                    historyDisclosure(review: review)
                        .padding(.top, 12)

                    streamLogDisclosure(review: review)
                        .padding(.top, 12)
                }
                .padding()
            }
        }
    }

    /// Returns the (possibly cached) grouping for `visible`. The cache key is
    /// derived from review id + finding ids/state ordinals + filter toggles.
    /// On a miss, regroups synchronously and stashes the result for the next
    /// body invocation.
    private func sectionsFor(visible: [Finding], review: Review) -> [FindingsGrouper.Section] {
        let key = sectionsCacheKey(visible: visible, review: review)
        if key == cachedSectionsKey, !cachedSections.isEmpty {
            return cachedSections
        }
        let grouped = FindingsGrouper.group(visible)
        DispatchQueue.main.async {
            cachedSections = grouped
            cachedSectionsKey = key
        }
        return grouped
    }

    /// Build a cheap string key encoding the inputs that affect grouping.
    /// Includes the finding state so toggle-triggered visibility changes
    /// invalidate the cache.
    private func sectionsCacheKey(visible: [Finding], review: Review) -> String {
        var key = review.id.uuidString
        key.reserveCapacity(key.count + visible.count * 40)
        key.append("|R")
        key.append(showResolved ? "1" : "0")
        key.append("D")
        key.append(showDismissed ? "1" : "0")
        for f in visible {
            key.append("|")
            key.append(f.id.uuidString)
            key.append(":")
            key.append(f.severity)
            key.append(":")
            key.append(f.state)
        }
        return key
    }

    @ViewBuilder
    private func schemaDecodeFailureContent(review: Review, message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            decodeWarningView(message: message)
            Divider()
            rawResultView(review: review)
                .frame(minHeight: 200, maxHeight: 360)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                historyDisclosure(review: review)
                streamLogDisclosure(review: review)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func terminalErrorContent(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            errorView(review: review)
                .frame(minHeight: 80)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                historyDisclosure(review: review)
                streamLogDisclosure(review: review)
            }
            .padding()
        }
    }

    // MARK: - Filter bar

    @ViewBuilder
    private func filterBar(review: Review) -> some View {
        let counts = stateCounts(review: review)
        HStack(spacing: 16) {
            Toggle("Show resolved", isOn: $showResolved)
                .toggleStyle(.checkbox)
                .help("\(counts.resolved) resolved finding\(counts.resolved == 1 ? "" : "s")")
            Toggle("Show dismissed", isOn: $showDismissed)
                .toggleStyle(.checkbox)
                .help("\(counts.dismissed) dismissed finding\(counts.dismissed == 1 ? "" : "s")")
            Spacer()
            Text(filterSummary(counts: counts))
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
        }
    }

    private struct StateCounts {
        let open: Int
        let resolved: Int
        let dismissed: Int
    }

    private func stateCounts(review: Review) -> StateCounts {
        var open = 0, resolved = 0, dismissed = 0
        for f in review.findings {
            switch f.state {
            case FindingState.resolved: resolved += 1
            case FindingState.dismissed: dismissed += 1
            default: open += 1
            }
        }
        return StateCounts(open: open, resolved: resolved, dismissed: dismissed)
    }

    private func filterSummary(counts: StateCounts) -> String {
        var parts: [String] = []
        parts.append("\(counts.open) open")
        if showResolved { parts.append("\(counts.resolved) resolved") }
        if showDismissed { parts.append("\(counts.dismissed) dismissed") }
        return parts.joined(separator: " · ")
    }

    /// Apply the resolved/dismissed toggles. `open` is always visible; the
    /// other two are off by default and require the user to opt in.
    private func filteredFindings(review: Review) -> [Finding] {
        return review.findings.filter { f in
            switch f.state {
            case FindingState.resolved:  return showResolved
            case FindingState.dismissed: return showDismissed
            default:                     return true
            }
        }
    }

    // MARK: - Severity sections

    @ViewBuilder
    private func severitySection(section: FindingsGrouper.Section) -> some View {
        let color = severityColor(section.severity)
        // Reuse the cached store rather than allocating one per finding row.
        let store = findingStateStore ?? FindingStateStore(context: modelContext)
        DisclosureGroup(
            isExpanded: .constant(true),
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items, id: \.id) { finding in
                        FindingRow(
                            finding: finding,
                            store: store,
                            onOpenInIntelliJ: { handleFindingClick(finding: finding) }
                        )
                    }
                }
                .padding(.top, 6)
            },
            label: {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 10, height: 10)
                    Text(severityDisplayName(section.severity))
                        .font(Font.display(size: 14, weight: .bold))
                        .foregroundStyle(Color.textPrimary)
                    Text("\(section.items.count)")
                        .font(Font.appBody(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.borderSubtle))
                    Spacer()
                }
            }
        )
        .padding(.vertical, 6)
    }

    private func severityDisplayName(_ key: String) -> String {
        switch key {
        case "blocker": return "Blocker"
        case "major":   return "Major"
        case "minor":   return "Minor"
        case "nit":     return "Nit"
        case "praise":  return "Praise"
        case "other":   return "Other"
        default:        return key.capitalized
        }
    }

    private func severityColor(_ key: String) -> Color {
        switch key {
        case "blocker":         return .accentTerracotta
        case "major":           return .accentMarigold
        case "minor":           return .accentFern
        case "nit":             return .accentGray
        case "praise":          return .accentFern
        default:                return .accentGray
        }
    }

    // MARK: - Empty / error helpers

    @ViewBuilder
    private func emptyFindingsMessage(review: Review) -> some View {
        let allCount = review.findings.count
        VStack(alignment: .leading, spacing: 6) {
            if allCount == 0 && (review.verdict ?? "").lowercased() == "approve" {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentFern)
                    Text("No issues — clean review")
                        .font(Font.appBody(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                }
            } else if allCount == 0 {
                Text("No findings.")
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textMuted)
            } else {
                Text("No findings match the current filters.")
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - Slice 14 — History disclosure

    /// Lists every Review row that shares the displayed review's `prKey`,
    /// newest-first. Clicking a row points the sheet at that historical
    /// review (read-only display; finding mutations still work because each
    /// Review owns its own findings). The currently-displayed row is shown
    /// highlighted in the list. Default-collapsed; only renders when at
    /// least two rows exist for the PR.
    @ViewBuilder
    private func historyDisclosure(review: Review) -> some View {
        let store = reviewStore ?? ReviewStore(context: modelContext)
        let allVersions = store.versions(prKey: review.prKey)
        if allVersions.count >= 2 {
            DisclosureGroup("History  ·  \(allVersions.count) reviews") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(allVersions, id: \.id) { entry in
                        historyRow(entry: entry, isCurrent: entry.id == review.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .font(Font.appBody(size: 13, weight: .semibold))
        }
    }

    /// One History row — timestamp, short sha, verdict, finding count, state.
    /// The whole row is a button so the user can click anywhere on it to
    /// switch the sheet's `historicalReviewID` binding.
    @ViewBuilder
    private func historyRow(entry: Review, isCurrent: Bool) -> some View {
        Button {
            // If this row is the live orchestrator current, clear the
            // historical override so the sheet re-binds to live state.
            if entry.id == orchestrator.current?.id {
                historicalReviewID = nil
            } else {
                historicalReviewID = entry.persistentModelID
            }
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(historyTimestampLabel(entry: entry))
                            .font(.caption.weight(.semibold))
                        Text(String(entry.headSha.prefix(7)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        historyVerdictPill(entry: entry)
                        historyStatePill(entry: entry)
                        Text("\(entry.findings.count) finding\(entry.findings.count == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isCurrent {
                    Text("Showing")
                        .font(Font.appBody(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentFern.opacity(0.18)))
                        .foregroundStyle(Color.accentFern)
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isCurrent ? Color.accentFern.opacity(0.06) : Color.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isCurrent ? Color.accentFern.opacity(0.30) : Color.borderSubtle,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(historyRowTooltip(entry: entry))
    }

    private func historyTimestampLabel(entry: Review) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: entry.startedAt, relativeTo: Date())
    }

    private func historyRowTooltip(entry: Review) -> String {
        let abs = entry.startedAt.formatted(date: .abbreviated, time: .standard)
        return "\(abs)\nsha: \(entry.headSha)"
    }

    @ViewBuilder
    private func historyVerdictPill(entry: Review) -> some View {
        let (label, color): (String, Color) = {
            switch (entry.verdict ?? "").lowercased() {
            case "approve":         return ("approve", Color.accentFern)
            case "request_changes": return ("changes", Color.accentTerracotta)
            case "comment":         return ("comment", Color.accentMarigold)
            default:                return ("—", Color.accentGray)
            }
        }()
        Text(label)
            .font(Font.appBody(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func historyStatePill(entry: Review) -> some View {
        let color: Color = {
            switch entry.state {
            case "completed":           return .accentFern
            case "running", "queued":   return .accentFern
            case "failed", "timeout":   return .accentMarigold
            case "cancelled":           return .accentGray
            default:                    return .accentGray
            }
        }()
        Text(entry.state)
            .font(Font.appBody(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
    }

    // MARK: - Stream log

    /// While `running` we render the stream big at the top of `content`.
    /// Once the run reaches a terminal state we want it accessible but not
    /// in the way — so it collapses into a disclosure that the user can
    /// reopen. Default-collapsed.
    @ViewBuilder
    private func streamLogDisclosure(review: Review) -> some View {
        DisclosureGroup("Stream log") {
            ScrollView {
                Text(review.partialStream.isEmpty ? "(no output)" : review.partialStream)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 240)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgSurface)
            )
        }
        .font(Font.appBody(size: 13, weight: .semibold))
    }

    @ViewBuilder
    private func streamView(review: Review) -> some View {
        // Drives off `throttledStream` (sampled ~30Hz from `review.partialStream`)
        // instead of the live property. Per-token `withAnimation` + scrollTo
        // makes selection jitter when claude emits hundreds of tokens per
        // second; 30Hz is the highest frame rate at which auto-scroll still
        // looks smooth.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(throttledStream.isEmpty ? "(no output yet)" : throttledStream)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("streamBottom")
                }
            }
            .onChange(of: throttledStream) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("streamBottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rawResultView(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Raw structured result")
                .font(Font.appBody(size: 11, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .padding(.horizontal)
                .padding(.top, 8)
            ScrollView {
                Text(review.rawResultJSON ?? "(no payload)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .background(Color.bgSurface)
        }
    }

    /// Soft warning rendered above the findings list when
    /// `ReviewStore.markCompleted` dropped one or more findings whose `file`
    /// didn't exist in the worktree. Uses the same marigold accent as
    /// `decodeWarningView` for visual consistency but stays multi-line so the
    /// dropped-path bullet list is readable.
    @ViewBuilder
    private func filterNoticeBanner(_ notice: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentMarigold)
            Text(notice)
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentMarigold.opacity(0.08))
    }

    @ViewBuilder
    private func decodeWarningView(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentMarigold)
            Text(message)
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentMarigold.opacity(0.08))
    }

    @ViewBuilder
    private func errorView(review: Review) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.accentTerracotta)
            VStack(alignment: .leading, spacing: 4) {
                Text(review.state == "timeout" ? "Timed out" : "Failed")
                    .font(Font.appBody(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(review.errorMessage ?? "(no error message captured)")
                    .font(Font.appBody(size: 11))
                    .foregroundStyle(Color.textMuted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
        .background(Color.accentTerracotta.opacity(0.08))
    }
}

// MARK: - Finding row

/// One finding card. Pulled into its own view so SwiftData observation on
/// `finding` re-renders just this row when the user flips its state, instead
/// of rebuilding the entire findings list.
private struct FindingRow: View {
    @Bindable var finding: Finding
    let store: FindingStateStore
    /// Slice 09 — invoked when the user taps the row body (anywhere except
    /// the state menu / icon button) or the explicit "open in IntelliJ"
    /// chevron. Both routes go through the same handler so they behave
    /// identically.
    let onOpenInIntelliJ: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Severity dot + raw severity label + optional category subtitle.
            HStack(spacing: 8) {
                Circle()
                    .fill(severityColor)
                    .frame(width: 8, height: 8)
                Text(finding.severity)
                    .font(Font.appBody(size: 11, weight: .semibold))
                    .foregroundStyle(severityColor)
                    .textCase(.uppercase)
                Spacer()
                openInIntelliJButton
                stateMenu
            }

            Text(finding.title)
                .font(Font.display(size: 13, weight: .bold))
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(fileLineLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.textMuted)
                .textSelection(.enabled)

            if !finding.message.isEmpty {
                messageView
            }

            if let suggestion = finding.suggestion, !suggestion.isEmpty {
                suggestionView(suggestion)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
        .opacity(finding.state == FindingState.dismissed ? 0.55 : 1.0)
        // Make the whole card area hit-testable, not just the text glyphs,
        // so tapping anywhere on the row jumps into IntelliJ. The state
        // menu and the icon button still capture their own taps because
        // SwiftUI gives child controls hit priority.
        .contentShape(Rectangle())
        .onTapGesture { onOpenInIntelliJ() }
    }

    /// Small explicit affordance on the right of the header row. Same action
    /// as tapping the row body, but with a clear icon so the click target is
    /// discoverable.
    @ViewBuilder
    private var openInIntelliJButton: some View {
        Button(action: onOpenInIntelliJ) {
            Image(systemName: "arrow.up.right.square")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .help("Open in IntelliJ at \(fileLineLabel)")
        .accessibilityLabel("Open in IntelliJ")
    }

    private var fileLineLabel: String {
        if let end = finding.endLine, end != finding.line {
            return "\(finding.file):\(finding.line)-\(end)"
        }
        return "\(finding.file):\(finding.line)"
    }

    /// Render `message` as markdown via `AttributedString(markdown:)` so
    /// claude's inline-code, bold, links surface correctly. If markdown
    /// parsing throws (rare — claude messages tend to be valid), fall back
    /// to plain Text so the user always sees something.
    @ViewBuilder
    private var messageView: some View {
        if let attributed = try? AttributedString(
            markdown: finding.message,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(finding.message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func suggestionView(_ suggestion: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Suggestion")
                .font(Font.appBody(size: 11, weight: .semibold))
                .foregroundStyle(Color.textMuted)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(suggestion)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.bgSurface)
            )
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var stateMenu: some View {
        Menu {
            Button("Open") { store.setState(finding, to: FindingState.open) }
            Button("Resolved") { store.setState(finding, to: FindingState.resolved) }
            Button("Dismissed") { store.setState(finding, to: FindingState.dismissed) }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(stateLabel)
                    .font(.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(stateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(stateColor.opacity(0.12)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var stateLabel: String {
        switch finding.state {
        case FindingState.resolved:  return "Resolved"
        case FindingState.dismissed: return "Dismissed"
        default:                     return "Open"
        }
    }

    private var stateColor: Color {
        switch finding.state {
        case FindingState.resolved:  return .accentFern
        case FindingState.dismissed: return .accentGray
        default:                     return .accentMarigold
        }
    }

    private var rowBackground: Color {
        switch finding.state {
        case FindingState.resolved:  return Color.accentFern.opacity(0.04)
        case FindingState.dismissed: return Color.accentGray.opacity(0.04)
        default:                     return Color.bgCard
        }
    }

    /// Map the (already-normalised) severity on `Finding` back to a colour.
    /// Mirrors `ReviewSheet.severityColor` so unknown-severity rows get a
    /// neutral gray dot in the row + matching gray section header.
    private var severityColor: Color {
        switch finding.severity.lowercased() {
        case "blocker", "critical": return .accentTerracotta
        case "major", "high":       return .accentMarigold
        case "minor", "medium":     return .accentFern
        case "nit", "low", "info":  return .accentGray
        case "praise":              return .accentFern
        default:                    return .accentGray
        }
    }
}
