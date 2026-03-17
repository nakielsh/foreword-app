//
//  SidebarView.swift
//  WorkHomepage
//
//  NavigationSplitView shell. One toolbar refresh button, one selected tab.
//  Slice/07-fix adds an "Active review" pill next to Refresh: visible only
//  when the orchestrator has a current run, click reopens the modal, the
//  small "X" clears the row reference once the run is done.
//

import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case reviews = "Reviews"
    case myPRs = "My PRs"
    case sessions = "Sessions"
    case deploys = "Deploys"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .reviews: return "checkmark.message"
        case .myPRs: return "person.crop.circle.badge"
        case .sessions: return "terminal"
        case .deploys: return "shippingbox"
        }
    }
}

struct SidebarView: View {
    @State private var selection: AppTab = .reviews
    /// Bumped on toolbar Refresh; ReviewsTab observes via `.onChange` to trigger a fetch.
    @State private var refreshTick: Int = 0
    /// Singleton orchestrator. Drives the active-review pill and re-opens
    /// the modal sheet from there.
    @State private var orchestrator = ReviewOrchestrator.shared
    /// True when the active-review modal is up via the pill click. ReviewsTab
    /// has its own boolean for the per-card path; both present the same
    /// orchestrator-driven sheet, so racing them is harmless.
    @State private var showReviewSheet: Bool = false

    /// Per-tab data containers. Held here (not in the tab views) so loaded
    /// state survives sidebar switches — SwiftUI tears down a tab's view tree
    /// on selection change, so any @State inside the tab would reset to zero.
    @State private var reviewsVM = ReviewsViewModel()
    @State private var myPRsVM = MyPRsViewModel()
    @State private var deploysVM = DeploysViewModel()

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
            }
            .navigationTitle("WorkHomepage")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            detail
                .toolbar {
                    if orchestrator.inFlightCount > 0 {
                        ToolbarItem(placement: .primaryAction) {
                            InFlightIndicator(orchestrator: orchestrator)
                        }
                    }
                    if orchestrator.current != nil {
                        ToolbarItem(placement: .primaryAction) {
                            ActiveReviewPill(
                                orchestrator: orchestrator,
                                onOpen: { showReviewSheet = true }
                            )
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            refreshTick &+= 1
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh the active tab")
                    }
                }
                .sheet(isPresented: $showReviewSheet) {
                    ReviewSheet(orchestrator: orchestrator)
                }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .reviews:
            ReviewsTab(vm: reviewsVM, refreshTick: refreshTick)
        case .myPRs:
            MyPRsTab(vm: myPRsVM, refreshTick: refreshTick)
        case .sessions:
            SessionsTab()
        case .deploys:
            DeploysTab(vm: deploysVM, refreshTick: refreshTick)
        }
    }
}

// MARK: - Active review pill

/// Small toolbar widget surfacing the orchestrator's current run. State dot +
/// `<repo>#<n>` label, click to re-open the modal. Trailing X clears
/// `orchestrator.current` once the run is done so the pill goes away.
private struct ActiveReviewPill: View {
    @Bindable var orchestrator: ReviewOrchestrator
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 8, height: 8)
                    Image(systemName: "wand.and.stars")
                        .font(.caption)
                    Text(label)
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(stateColor.opacity(0.12)))
                .foregroundStyle(stateColor)
            }
            .buttonStyle(.plain)
            .help("Open active review")

            // Dismiss the pill (clears orchestrator.current) — only enabled
            // when the run is in a terminal state. We never let the user
            // lose the UI handle to a still-running process.
            if !orchestrator.isRunning {
                Button {
                    orchestrator.clearCurrent()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
    }

    private var label: String {
        guard let r = orchestrator.current else { return "—" }
        return "\(r.repoFullName)#\(r.prNumber)"
    }

    private var stateColor: Color {
        switch orchestrator.current?.state {
        case "running":   return .blue
        case "completed": return .green
        case "failed":    return .red
        case "timeout":   return .orange
        default:          return .gray
        }
    }
}

// MARK: - In-flight indicator (slice 13)

/// Compact toolbar widget showing how many reviews are running and how many
/// are queued, against the configured concurrency cap. Visible only when at
/// least one review is in-flight (running or queued).
private struct InFlightIndicator: View {
    @Bindable var orchestrator: ReviewOrchestrator

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "gearshape.2")
                .font(.caption)
            Text("\(orchestrator.running.count)/\(AppSettings.concurrencyCap) · queued \(orchestrator.queued.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.blue.opacity(0.10)))
        .foregroundStyle(.blue)
        .help("\(orchestrator.running.count) running, \(orchestrator.queued.count) queued · cap \(AppSettings.concurrencyCap)")
    }
}

#Preview {
    SidebarView()
}
