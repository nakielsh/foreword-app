//
//  PreReviewSummaryStore.swift
//  WorkHomepage
//
//  Slice 24 — Pre-Review Summary tracer.
//
//  Thin SwiftData wrapper for `PreReviewSummary` rows. Mirrors the shape of
//  `ReviewStore` but is scoped purely to the summary pipeline — no findings,
//  no state machine, no partial streaming. The caller passes a `ModelContext`
//  (typically `@Environment(\.modelContext)` from the Reviews tab).
//
//  `dropForPR` is hooked into the closed-PR cleanup path in
//  `ClosedPRDetector.cleanupClosedPRs` so stale summaries are evicted when
//  the PR closes, matching the Review cleanup contract.
//

import Foundation
import SwiftData

@MainActor
final class PreReviewSummaryStore {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Queries

    /// Returns the cached summary for the given `(prKey, headSha)` pair, or
    /// nil if none exists. A new headSha produces a cache miss even if an
    /// older summary exists for the same PR.
    func existing(prKey: String, headSha: String) -> PreReviewSummary? {
        let compositeId = "\(prKey)|\(headSha)"
        let descriptor = FetchDescriptor<PreReviewSummary>(
            predicate: #Predicate { $0.id == compositeId }
        )
        return (try? context.fetch(descriptor))?.first
    }

    // MARK: - Mutations

    /// Insert or overwrite a summary. Uses `context.insert` then saves.
    /// SwiftData's `@Attribute(.unique)` on `id` means a second save for the
    /// same `(prKey, headSha)` is silently ignored (upsert semantics are not
    /// guaranteed, but the caller only calls `save` once per run and `existing`
    /// guards the hot path).
    func save(_ summary: PreReviewSummary) {
        context.insert(summary)
        try? context.save()
    }

    /// Drop every `PreReviewSummary` row for `prKey`, regardless of `headSha`.
    /// Called by the closed-PR cleanup path so stale summaries don't accumulate
    /// for PRs that have been merged or closed. No-op when no rows exist.
    func dropForPR(_ prKey: String) {
        let descriptor = FetchDescriptor<PreReviewSummary>(
            predicate: #Predicate { $0.prKey == prKey }
        )
        guard let rows = try? context.fetch(descriptor) else { return }
        if rows.isEmpty { return }
        for row in rows {
            context.delete(row)
        }
        try? context.save()
    }
}
