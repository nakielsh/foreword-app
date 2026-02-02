//
//  SidebarView.swift
//  WorkHomepage
//
//  NavigationSplitView shell. One toolbar refresh button, one selected tab.
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
            ReviewsTab(refreshTick: refreshTick)
        case .myPRs:
            MyPRsTab()
        case .sessions:
            SessionsTab()
        case .deploys:
            DeploysTab()
        }
    }
}

#Preview {
    SidebarView()
}
