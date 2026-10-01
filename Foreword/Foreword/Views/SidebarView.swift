//
//  SidebarView.swift
//  Foreword
//
//  NavigationSplitView shell. One toolbar refresh button, one selected tab.
//  Slice/07-fix adds an "Active review" pill next to Refresh: visible only
//  when the orchestrator has a current run, click reopens the modal, the
//  small "X" clears the row reference once the run is done.
//

import SwiftUI
import Foundation

extension Notification.Name {
    /// Fired by SidebarView's "Active review" pill to ask the foregrounded
    /// `ReviewsTab` to open the review sheet. Single owner of the sheet
    /// `@State` is `ReviewsTab`; the sidebar pill routes through this
    /// notification so we don't end up with two competing
    /// `.sheet(isPresented:)` modifiers fighting over dismiss events.
    static let reviewSheetOpenRequested = Notification.Name("reviewSheetOpenRequested")
}

enum AppTab: String, CaseIterable, Identifiable {
    case reviews = "Reviews"
    case myPRs = "My PRs"
    case sessions = "Sessions"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .reviews: return "checkmark.message"
        case .myPRs: return "person.crop.circle.badge"
        case .sessions: return "terminal"
        }
    }
}

struct SidebarView: View {
    @State private var selection: AppTab = .reviews
    /// Bumped on toolbar Refresh; ReviewsTab observes via `.onChange` to trigger a fetch.
    @State private var refreshTick: Int = 0
    /// Singleton orchestrator. Drives the active-review pill — `let` because
    /// `@Observable` instances don't need (and shouldn't have) `@State`'s
    /// identity bookkeeping when the value is a long-lived shared singleton.
    private let orchestrator = ReviewOrchestrator.shared

    /// Per-tab data containers. Held here (not in the tab views) so loaded
    /// state survives sidebar switches — SwiftUI tears down a tab's view tree
    /// on selection change, so any @State inside the tab would reset to zero.
    @State private var reviewsVM = ReviewsViewModel()
    @State private var myPRsVM = MyPRsViewModel()

    var body: some View {
        NavigationSplitView {
            List(AppTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.systemImage)
                }
            }
            .navigationTitle("Foreword")
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
                                onOpen: {
                                    // Route the pill click through a notification
                                    // so ReviewsTab — the canonical owner of
                                    // `showReviewSheet` — opens the sheet. Avoids
                                    // two competing `.sheet(isPresented:)` modifiers
                                    // that would race on dismiss events.
                                    // Switch to the Reviews tab first so the
                                    // observer is alive when the post lands.
                                    selection = .reviews
                                    DispatchQueue.main.async {
                                        NotificationCenter.default.post(
                                            name: .reviewSheetOpenRequested,
                                            object: nil
                                        )
                                    }
                                }
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
        case "running":   return .accentFern
        case "completed": return .accentFern
        case "failed":    return .accentTerracotta
        case "timeout":   return .accentMarigold
        default:          return .accentGray
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
                .font(Font.appBody(size: 11))
            Text("\(orchestrator.running.count)/\(AppSettings.concurrencyCap) · queued \(orchestrator.queued.count)")
                .font(Font.mono(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.accentFern.opacity(0.10)))
        .foregroundStyle(Color.accentFern)
        .help("\(orchestrator.running.count) running, \(orchestrator.queued.count) queued · cap \(AppSettings.concurrencyCap)")
    }
}

#Preview {
    SidebarView()
}
