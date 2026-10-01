//
//  ReviewVersioning.swift
//  Foreword
//
//  Slice 14 — Review versioning + history view.
//
//  Pure decision helper that encodes the slice 14 "should we start a new
//  run?" rule, factored out of `ReviewsTab.startReview` so it can be unit
//  tested without dragging in SwiftUI / orchestrator state.
//
//  Rule (per docs/issues/14-review-versioning-and-history.md):
//
//    1. If no Review exists yet for the current `(prKey, headSha)` pair,
//       always start a new run (existing == nil → true).
//    2. If one exists AND the user did NOT click "Re-review", reuse the
//       existing row IFF that row reached a terminal-success state
//       (`completed`). Failed / timeout / cancelled runs are treated as
//       "didn't really happen" — clicking Review on those should re-run.
//    3. The "Re-review" button (force = true) always wins: even if the
//       existing row is `completed`, force a fresh run. The new row is
//       inserted alongside; the old one is preserved (orchestrator's
//       `start(...)` already creates a new Review row each time).
//
//  Slice 13's `running` / `queued` states are intentionally NOT considered
//  "existing for this sha" by callers — `ReviewsTab.pendingForPR` already
//  intercepts those and the per-card button shows Cancel instead of Review.
//  We assume the caller has already established that there's no in-flight
//  review for this PR before consulting this helper.
//

import Foundation

enum ReviewVersioning {

    /// Decides whether clicking "Review" should start a new orchestrator run
    /// or reuse the existing row.
    ///
    /// - Parameters:
    ///   - existingForSha: The most recent Review row that matches the
    ///     current `(prKey, headSha)` pair, or nil if none exists.
    ///   - force: True iff the user clicked the explicit "Re-review" button
    ///     in the modal; false for a normal Review-button click.
    /// - Returns: `true` to call `orchestrator.start(...)`; `false` to just
    ///   open the modal on the existing row.
    static func shouldStartNewRun(existingForSha: Review?, force: Bool) -> Bool {
        if force { return true }
        guard let existing = existingForSha else { return true }
        // Only a cleanly-completed row is reusable. Any other terminal state
        // (failed / timeout / cancelled) means the previous attempt didn't
        // produce a usable verdict, so the click should re-run instead of
        // surfacing a dead row.
        return existing.state != "completed"
    }
}
