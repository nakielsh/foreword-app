//
//  ReviewSheet.swift
//  WorkHomepage
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

struct ReviewSheet: View {

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The same singleton instance ReviewsTab and SidebarView read from. The
    /// sheet's content derives from `orchestrator.current`; whenever the
    /// orchestrator transitions to a new run, the sheet (if open) follows
    /// automatically.
    @Bindable var orchestrator: ReviewOrchestrator

    /// Filter toggles persist across launches per PRD Q8d so the user
    /// doesn't have to re-hide noise each time they open a review.
    @AppStorage("findings.showResolved") private var showResolved: Bool = false
    @AppStorage("findings.showDismissed") private var showDismissed: Bool = false

    // MARK: - Slice 09: launcher feedback
    //
    // A single piece of state captures the most recent launch outcome so the
    // sheet can surface the right affordance:
    //   - `.openedInIntelliJ`            → no UI feedback
    //   - `.openedWithoutLineJump`       → 3s auto-dismissing toast banner
    //   - `.fileMissing` / `.failed`     → modal alert with OK
    @State private var launcherToastMessage: String?
    @State private var launcherAlertMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(Color.gray.opacity(0.06))

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                cancelButtonIfNeeded
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 560)
        .overlay(alignment: .top) {
            if let toast = launcherToastMessage {
                launcherToast(message: toast)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
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
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.thickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1)
        )
        .shadow(radius: 4)
    }

    // MARK: - Launcher dispatch

    /// Builds the worktree URL for the current review and launches IntelliJ
    /// at `file:line`. Maps `FallbackResult` cases onto toast / alert state
    /// so the body's overlays render the right feedback.
    private func handleFindingClick(finding: Finding) {
        guard let review = orchestrator.current else { return }
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
            launcherAlertMessage = "File not found in worktree: \(url.path)"
        case .failed(let msg):
            launcherAlertMessage = "Could not open file: \(msg)"
        }
    }

    /// Shows a toast for ~3s, dismissing automatically. Re-showing the same
    /// toast resets the timer.
    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            launcherToastMessage = message
        }
        let captured = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            // Only clear if the visible toast is still the one we showed —
            // otherwise a later toast would get clobbered by this stale timer.
            if launcherToastMessage == captured {
                withAnimation(.easeInOut(duration: 0.2)) {
                    launcherToastMessage = nil
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(orchestrator.current?.repoFullName ?? "—")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.18)))
                if let n = orchestrator.current?.prNumber {
                    Text("#\(n)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                stateBadge
            }
            if let review = orchestrator.current {
                Text("branch: \(review.headBranch)  ·  sha: \(review.headSha.prefix(8))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    verdictBadge(review: review)
                    if let summary = review.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.title3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                jiraAlignmentBlock(review: review)
            }
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        let state = orchestrator.current?.state ?? "idle"
        let (label, color): (String, Color) = {
            switch state {
            case "queued": return ("Queued", .gray)
            case "running": return ("Running", .blue)
            case "completed": return ("Completed", .green)
            case "failed": return ("Failed", .red)
            case "timeout": return ("Timed out", .orange)
            case "cancelled": return ("Cancelled", .gray)
            default: return ("Idle", .gray)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    /// Slice 13 cancel button. Visible only when the focused review is
    /// queued or running. Routes to `orchestrator.cancel(_:)`. Cancelling a
    /// queued review removes it from the queue (no spawn). Cancelling a
    /// running review SIGTERMs the underlying child and flips the row's
    /// state to `cancelled`.
    @ViewBuilder
    private var cancelButtonIfNeeded: some View {
        if let cur = orchestrator.current, cur.state == "running" || cur.state == "queued" {
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

    /// Verdict capsule — colored per PRD Q4b: approve→green, request_changes
    /// →red, comment→orange. Anything else (or nil) renders as a muted
    /// "No verdict" pill so the user still sees the slot.
    @ViewBuilder
    private func verdictBadge(review: Review) -> some View {
        let (label, color): (String, Color) = {
            switch (review.verdict ?? "").lowercased() {
            case "approve":         return ("Approve", .green)
            case "request_changes": return ("Request changes", .red)
            case "comment":         return ("Comment", .orange)
            case "":                return ("No verdict", .gray)
            default:                return (review.verdict ?? "Unknown", .gray)
            }
        }()
        Text(label)
            .font(.callout.weight(.semibold))
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
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jira alignment")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.25), lineWidth: 1)
            )
        }
    }

    /// Re-decode just the `jira_alignment.notes` out of the raw payload.
    /// Slice 07's `Review` model doesn't persist this field directly — only
    /// summary and verdict — so we lazily pull it from `rawResultJSON`. The
    /// decode is cheap and runs once per body invocation; if it ever shows
    /// up in profiling the right fix is to add a dedicated field on
    /// `Review`, not to cache it here.
    private func jiraAlignmentNotes(for review: Review) -> String? {
        guard let raw = review.rawResultJSON,
              let data = raw.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        guard let schema = try? decoder.decode(ReviewSchema.self, from: data) else {
            return nil
        }
        return schema.jiraAlignment?.notes
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let rejection = orchestrator.lastRejection, orchestrator.current == nil {
            VStack {
                Spacer()
                Text(rejection)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding()
                Spacer()
            }
        } else if let review = orchestrator.current {
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
                .font(.callout)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.gray)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cancelled")
                        .font(.subheadline.weight(.semibold))
                    Text(review.errorMessage ?? "Review was cancelled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding()
            .background(Color.gray.opacity(0.08))

            Divider()

            streamLogDisclosure(review: review)
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
    /// collapsed at the bottom.
    @ViewBuilder
    private func findingsContent(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        let sections = FindingsGrouper.group(visible)
                        ForEach(sections, id: \.severity) { section in
                            severitySection(section: section)
                        }
                    }

                    streamLogDisclosure(review: review)
                        .padding(.top, 12)
                }
                .padding()
            }
        }
    }

    @ViewBuilder
    private func schemaDecodeFailureContent(review: Review, message: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            decodeWarningView(message: message)
            Divider()
            rawResultView(review: review)
                .frame(minHeight: 200, maxHeight: 360)
            Divider()
            streamLogDisclosure(review: review)
                .padding()
        }
    }

    @ViewBuilder
    private func terminalErrorContent(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            errorView(review: review)
                .frame(minHeight: 80)
            Divider()
            streamLogDisclosure(review: review)
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
                .font(.caption)
                .foregroundStyle(.secondary)
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
        DisclosureGroup(
            isExpanded: .constant(true),
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(section.items, id: \.id) { finding in
                        FindingRow(
                            finding: finding,
                            store: FindingStateStore(context: modelContext),
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
                        .font(.headline)
                    Text("\(section.items.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
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
        case "blocker": return .red
        case "major":   return .orange
        case "minor":   return .yellow
        case "nit":     return .blue
        case "praise":  return .green
        default:        return .gray
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
                        .foregroundStyle(.green)
                    Text("No issues — clean review")
                        .font(.callout.weight(.semibold))
                }
            } else if allCount == 0 {
                Text("No findings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("No findings match the current filters.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
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
                    .fill(Color.gray.opacity(0.05))
            )
        }
        .font(.callout.weight(.semibold))
    }

    @ViewBuilder
    private func streamView(review: Review) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(review.partialStream.isEmpty ? "(no output yet)" : review.partialStream)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("streamBottom")
                }
            }
            .onChange(of: review.partialStream) { _, _ in
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
            .background(Color.gray.opacity(0.05))
        }
    }

    @ViewBuilder
    private func decodeWarningView(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    @ViewBuilder
    private func errorView(review: Review) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(review.state == "timeout" ? "Timed out" : "Failed")
                    .font(.subheadline.weight(.semibold))
                Text(review.errorMessage ?? "(no error message captured)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.08))
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
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(severityColor)
                    .textCase(.uppercase)
                Spacer()
                openInIntelliJButton
                stateMenu
            }

            Text(finding.title)
                .font(.body.weight(.semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(fileLineLabel)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
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
                .stroke(Color.gray.opacity(0.18), lineWidth: 1)
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
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(suggestion)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.gray.opacity(0.12))
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
        case FindingState.resolved:  return .green
        case FindingState.dismissed: return .gray
        default:                     return .blue
        }
    }

    private var rowBackground: Color {
        switch finding.state {
        case FindingState.resolved:  return Color.green.opacity(0.04)
        case FindingState.dismissed: return Color.gray.opacity(0.04)
        default:                     return Color.gray.opacity(0.02)
        }
    }

    /// Map the (already-normalised) severity on `Finding` back to a colour.
    /// Mirrors `ReviewSheet.severityColor` so unknown-severity rows get a
    /// neutral gray dot in the row + matching gray section header.
    private var severityColor: Color {
        switch finding.severity.lowercased() {
        case "blocker", "critical": return .red
        case "major", "high":       return .orange
        case "minor", "medium":     return .yellow
        case "nit", "low", "info":  return .blue
        case "praise":              return .green
        default:                    return .gray
        }
    }
}
