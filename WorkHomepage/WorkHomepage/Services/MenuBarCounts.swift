//
//  MenuBarCounts.swift
//  WorkHomepage
//
//  Slice 16 — MenuBarExtra companion.
//
//  Tiny shared bag of counts that the menu-bar label reads. Two numbers:
//
//   - `awaitingReviews` — PRs review-requested and not yet reviewed by the
//     user. Sourced from the Reviews tab. Slice 16 cannot modify `ReviewsTab`
//     (per the slice's hard merge-conflict-avoidance rules), so the seam is a
//     `NotificationCenter` notification: anyone who knows the count posts
//     `Notification.Name.reviewsAwaitingCountChanged` with `userInfo["count"]
//     = Int`. A future slice should swap the `NotificationCenter` for a
//     direct `@Observable` binding once `ReviewsTab` can be refactored.
//
//   - `inFlightReviews` — number of running reviews. Slice 07 has at most one
//     concurrent review (single-flight), so this is `0` or `1`, derived
//     reactively from `ReviewOrchestrator.shared.current?.state`. Slice 13
//     introduces a real queue and will replace this with `running + queued`.
//
//  Both values are `@Observable` properties, so SwiftUI views (the
//  `MenuBarExtra` label in particular) re-render automatically.
//

import Foundation
import Observation

extension Notification.Name {
    /// Posted whenever the awaiting-review count changes. UserInfo:
    /// `["count": Int]`. The receiver is `MenuBarCounts.shared`. The Reviews
    /// tab is the canonical poster (slice 16 doesn't wire the poster yet —
    /// see this file's header comment for the seam rationale).
    static let reviewsAwaitingCountChanged = Notification.Name("reviewsAwaitingCountChanged")

    /// Posted by the MenuBarExtra "Refresh Reviews" item. The Reviews tab (or
    /// any future receiver) listens and triggers its refresh path. Slice 16
    /// only posts; wiring the receiver is left to a follow-up slice that may
    /// modify `ReviewsTab`.
    static let refreshReviewsRequested = Notification.Name("refreshReviewsRequested")
}

@MainActor
@Observable
final class MenuBarCounts {

    /// Process-wide singleton. The `MenuBarExtra` label binds to this and
    /// re-renders as the properties change.
    static let shared = MenuBarCounts()

    /// Number of PRs awaiting the user's review. Updated externally — either
    /// directly via `setAwaiting(_:)` or by posting
    /// `.reviewsAwaitingCountChanged`. Defaults to `0`.
    var awaitingReviews: Int = 0

    /// Number of currently in-flight reviews. Derived reactively from
    /// `ReviewOrchestrator.shared` via an observation watcher set up in
    /// `init`. Slice 07's single-flight orchestrator means this is `0` or `1`.
    var inFlightReviews: Int = 0

    /// Token for the awaiting-count notification observer. Held so it can be
    /// torn down if the instance is deallocated. The singleton lives for the
    /// app's lifetime, but tests construct fresh instances and rely on
    /// observer cleanup on dealloc. `nonisolated(unsafe)` is required so
    /// `deinit` (a non-isolated context) can read it; the observer itself is
    /// only ever assigned from the main-actor `init`, so the unsafe carve-out
    /// is sound.
    private nonisolated(unsafe) var awaitingObserver: NSObjectProtocol?

    init() {
        // Listen for awaiting-count updates posted from the Reviews tab (or
        // any other source). UserInfo["count"] should be an `Int`.
        awaitingObserver = NotificationCenter.default.addObserver(
            forName: .reviewsAwaitingCountChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let raw = note.userInfo?["count"] as? Int ?? 0
            // Hop to the main actor to satisfy the actor isolation contract.
            // `queue: .main` already runs us on the main thread, but the
            // closure is non-isolated so we need an explicit hop.
            Task { @MainActor in
                self.awaitingReviews = max(0, raw)
            }
        }

        // React to orchestrator state. `withObservationTracking` re-arms each
        // time a tracked property changes, so we re-subscribe inside the
        // change handler. This mirrors `ReviewOrchestrator.shared.current?.
        // state` into `inFlightReviews` without polling.
        rearmInFlightWatcher()
    }

    deinit {
        if let awaitingObserver {
            NotificationCenter.default.removeObserver(awaitingObserver)
        }
    }

    /// Set the awaiting-review count directly. Tests use this to verify
    /// observation; production code typically posts `.reviewsAwaitingCountChanged`
    /// instead, but both code paths land at the same property.
    func setAwaiting(_ n: Int) {
        awaitingReviews = max(0, n)
    }

    /// Increment the in-flight count. Slice 13 will replace the orchestrator
    /// watcher with explicit bump/drop calls keyed to queue events; for now
    /// `bumpInFlight` and `dropInFlight` are exposed for tests and future
    /// callers.
    func bumpInFlight() {
        inFlightReviews += 1
    }

    /// Decrement the in-flight count, never going negative.
    func dropInFlight() {
        inFlightReviews = max(0, inFlightReviews - 1)
    }

    // MARK: - Orchestrator watcher

    /// Recomputes `inFlightReviews` from `ReviewOrchestrator.shared` and
    /// re-arms the observation. `withObservationTracking` fires its change
    /// closure exactly once when any tracked property changes, so we have to
    /// re-arm each time to keep the watcher alive.
    private func rearmInFlightWatcher() {
        let snapshot = withObservationTracking {
            // Read everything we want to track. Reading `current?.state`
            // tracks both `current` and (transitively) the Review's `state`.
            let orchestrator = ReviewOrchestrator.shared
            return orchestrator.current?.state == "running" ? 1 : 0
        } onChange: { [weak self] in
            // Hop to the main actor — `onChange` runs on whatever scheduler
            // posted the change.
            Task { @MainActor in
                self?.rearmInFlightWatcher()
            }
        }
        // Apply the latest reading.
        if inFlightReviews != snapshot {
            inFlightReviews = snapshot
        }
    }
}
