//
//  ClosedPRDetector.swift
//  WorkHomepage
//
//  Slice 15 — PR close → drop reviews + worktree.
//  Slice 24 — Also drop Pre-Review Summary rows on PR close.
//
//  The Reviews-tab refresh fans out two GitHub queries (`review-requested:@me`
//  and `reviewed-by:@me`). Both filter to `is:open`, so any PR that was
//  previously tracked but no longer appears in either result set is, by
//  definition, closed or merged. This detector sweeps those out:
//
//   - Tracked set: every distinct `prKey` with at least one `Review` row.
//   - Open set: union of `prKey`s seen on the most recent Reviews-tab refresh.
//   - Cleanup set: tracked − open.
//
//  For each cleanup-set entry we evict the worktree (preserving the bare
//  clone — bare clones are repo-scoped and shared across PRs) and drop the
//  Review + Finding rows for that PR.
//
//  Slice 24 adds `summaryStore` — when non-nil, `dropForPR` is also called on
//  it so Pre-Review Summary rows are evicted alongside Review rows.
//
//  The orchestrator owns running reviews, so we defensively skip any prKey
//  whose latest review is in `running` state. Yanking state out from under a
//  running review would leave the orchestrator referencing a deleted SwiftData
//  row and could race against `markCompleted`.
//
//  The evictor + the running-state predicate are both injected so tests can
//  drive the full state machine without spawning subprocesses or mutating the
//  shared `ReviewOrchestrator.shared` singleton (which is `@MainActor`-bound).
//

import Foundation
import os

@MainActor
struct ClosedPRDetector {

    /// SwiftData write path for the cleanup. Provides `distinctTrackedPRKeys`
    /// (the input) and `dropForPR` (the destructive output).
    let store: ReviewStore

    /// Slice 24: optional Pre-Review Summary store to also clean up on PR close.
    let summaryStore: PreReviewSummaryStore?

    /// Worktree eviction. Production injects `WorktreeManager.evict`; tests
    /// inject a recorder. Throwing is tolerated — a failed evict logs and
    /// proceeds with the SwiftData drop so the UI doesn't get stuck showing
    /// reviews for a long-closed PR just because git misbehaved.
    let evictor: (String, Int) throws -> Void

    /// "Is this prKey in `running` state right now?" Defaults to a fetch
    /// against the same store. Tests inject a stub.
    let isRunning: (String) -> Bool

    init(
        store: ReviewStore,
        summaryStore: PreReviewSummaryStore? = nil,
        evictor: @escaping (String, Int) throws -> Void = WorktreeManager.evict,
        isRunning: ((String) -> Bool)? = nil
    ) {
        self.store = store
        self.summaryStore = summaryStore
        self.evictor = evictor
        // Default running-state predicate: latest review row for this PR
        // exists and is `state == "running"`. Wrapped here so the closure
        // captures the store rather than re-resolving it per call.
        self.isRunning = isRunning ?? { key in
            store.latestForPR(prKey: key)?.state == "running"
        }
    }

    /// Sweeps every tracked PR not in `openPRKeys`, evicting + dropping each.
    /// Returns the count of cleaned-up PRs.
    ///
    /// Note: this entry point invokes `evictor` synchronously, which on the
    /// production path spawns `git worktree remove`. New code should prefer
    /// `cleanupClosedPRsAsync(...)` which moves the spawn to a detached
    /// task. Kept here for backward compatibility with the existing UI
    /// caller until that's migrated.
    @discardableResult
    func cleanupClosedPRs(openPRKeys: Set<String>) -> Int {
        let tracked = store.distinctTrackedPRKeys()
        var cleaned = 0
        for key in tracked where !openPRKeys.contains(key) {
            // Defensive: do not touch a PR that the orchestrator is still
            // running against. The orchestrator's own terminal-state save
            // will rewrite the row; we'll catch it on the next sweep.
            if isRunning(key) { continue }

            guard let parsed = parsePRKey(key) else { continue }
            do {
                try evictor(parsed.repo, parsed.prNumber)
            } catch {
                Logger(subsystem: "ClosedPRDetector", category: "cleanup")
                    .error("evict failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
                // Fall through — still drop the rows. The bare clone survives
                // either way; worst case is an orphaned worktree dir that the
                // disk-usage screen (slice 17) can clean.
            }
            store.dropForPR(prKey: key)
            // Slice 24: also evict any Pre-Review Summary rows for this PR.
            summaryStore?.dropForPR(key)
            cleaned += 1
        }
        return cleaned
    }

    /// Async variant. The eviction step (`evictor`) — which on the production
    /// path spawns `git worktree remove` and `git worktree prune` and is
    /// I/O-bound — runs on a detached task so we don't block the calling
    /// actor while git fetches its locks. SwiftData mutations
    /// (`store.dropForPR`, `summaryStore?.dropForPR`) stay on the calling
    /// actor because `ReviewStore` / `PreReviewSummaryStore` borrow the
    /// caller's `ModelContext`, which is actor-bound.
    ///
    /// Functionally equivalent to `cleanupClosedPRs(openPRKeys:)` from the
    /// caller's perspective: same return value, same skip semantics for
    /// running reviews and malformed prKeys.
    @discardableResult
    func cleanupClosedPRsAsync(openPRKeys: Set<String>) async -> Int {
        let tracked = store.distinctTrackedPRKeys()
        var cleaned = 0
        for key in tracked where !openPRKeys.contains(key) {
            if isRunning(key) { continue }
            guard let parsed = parsePRKey(key) else { continue }
            // Hop off the calling actor for the spawn. The evictor closure
            // is invoked from the detached task; production injects
            // `WorktreeManager.evict` (a pure static), tests inject a class
            // method recorder. We use a continuation rather than passing the
            // closure into a `Task.detached` body so we don't run into
            // sendable-capture friction (the closure type is `(String, Int)
            // throws -> Void`, which isn't `@Sendable`).
            let repo = parsed.repo
            let prNumber = parsed.prNumber
            let capturedEvictor = self.evictor
            let evictResult: Result<Void, Error> = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try capturedEvictor(repo, prNumber)
                        cont.resume(returning: .success(()))
                    } catch {
                        cont.resume(returning: .failure(error))
                    }
                }
            }
            if case .failure(let error) = evictResult {
                Logger(subsystem: "ClosedPRDetector", category: "cleanup")
                    .error("evict failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            store.dropForPR(prKey: key)
            summaryStore?.dropForPR(key)
            cleaned += 1
        }
        return cleaned
    }

    // MARK: - Internals

    /// `prKey` shape is `<org>/<repo>#<number>`. Splits on `#` then on `/`.
    /// Returns nil for any input that doesn't satisfy the three-part contract;
    /// the caller skips that key rather than throwing.
    static func parsePRKey(_ key: String) -> (repo: String, prNumber: Int)? {
        let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let repoPart = String(parts[0])
        let numPart = String(parts[1])
        guard !repoPart.isEmpty, !numPart.isEmpty else { return nil }
        let repoBits = repoPart.split(separator: "/", omittingEmptySubsequences: false)
        guard repoBits.count == 2,
              !repoBits[0].isEmpty,
              !repoBits[1].isEmpty else { return nil }
        guard let n = Int(numPart) else { return nil }
        return (repoPart, n)
    }

    /// Instance method form so callers don't have to know about the static.
    private func parsePRKey(_ key: String) -> (repo: String, prNumber: Int)? {
        Self.parsePRKey(key)
    }
}
