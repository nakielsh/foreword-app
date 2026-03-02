//
//  FindingStateStore.swift
//  WorkHomepage
//
//  Slice 08 — Findings UI.
//
//  Thin wrapper around the SwiftData write that flips a `Finding.state`
//  between `open`, `resolved`, and `dismissed`. Pulled out of the view so the
//  state-mutation path is testable in isolation (no SwiftUI environment, no
//  observation graph) and so the view never directly issues `context.save()`.
//
//  Slice 07 already declared `Finding.state` (defaulted to `"open"`); this
//  store owns the legal transitions for slice 08's UI. State is local-only —
//  per the PRD, finding state is never written back to GitHub or Jira.
//

import Foundation
import SwiftData

/// Allowed values for `Finding.state`. Stored as raw strings on the model
/// (SwiftData migration friendliness), but centralised here so the rest of
/// the app can refer to them by name.
enum FindingState {
    static let open = "open"
    static let resolved = "resolved"
    static let dismissed = "dismissed"

    /// Returns true when the value is one of the known states. Used by the
    /// store to ignore typos / future states without crashing.
    static func isKnown(_ raw: String) -> Bool {
        return raw == open || raw == resolved || raw == dismissed
    }
}

@MainActor
struct FindingStateStore {
    let context: ModelContext

    /// Sets the finding's state and persists. Unknown state strings are
    /// silently ignored — callers should pass one of `FindingState.open`,
    /// `FindingState.resolved`, or `FindingState.dismissed`.
    func setState(_ finding: Finding, to state: String) {
        guard FindingState.isKnown(state) else { return }
        finding.state = state
        try? context.save()
    }
}
