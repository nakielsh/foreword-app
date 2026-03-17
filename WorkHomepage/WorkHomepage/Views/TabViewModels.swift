//
//  TabViewModels.swift
//  WorkHomepage
//
//  Persistent per-tab data containers held by SidebarView. SwiftUI tears down
//  tab views on selection switch, so any `@State` inside ReviewsTab / MyPRsTab
//  / DeploysTab dies the moment the user clicks another sidebar entry. Holding
//  the data here — owned by SidebarView's lifetime — preserves the loaded
//  state across tab switches. Tabs read/write through a `@Bindable` reference.
//

import Foundation
import Observation

@Observable
final class ReviewsViewModel {
    var pendingPRs: [PendingReviewPR] = []
    var reviewedPRs: [ReviewedPR] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var hasFetchedOnce: Bool = false
    var currentUser: String?
}

@Observable
final class MyPRsViewModel {
    var rows: [MyPRRow] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var hasFetchedOnce: Bool = false
    var currentUser: String?
}

@Observable
final class DeploysViewModel {
    var serviceStates: [String: DeployServiceCardState] = [:]
    var globalError: String?
    var hasRefreshedOnce: Bool = false
}

/// Card state surfaced by DeploysTab. Lifted out of the tab so the view model
/// can store it across tab switches.
enum DeployServiceCardState {
    case loading
    case loaded([Deployment])
    case unauthorized
    case error(String)
}
