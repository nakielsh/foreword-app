//
//  ReviewStore.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Thin wrapper over SwiftData ops for `Review` and `Finding` rows. Caller
//  passes the `ModelContext` (typically `@Environment(\.modelContext)` from a
//  view, or the orchestrator's borrowed context). Keeps query / save plumbing
//  out of the orchestrator and out of the view.
//

import Foundation
import SwiftData

@MainActor
struct ReviewStore {
    let context: ModelContext

    // MARK: - Insert

    /// Creates and inserts a new `Review` row in `running` state. Returns the
    /// inserted row so the orchestrator can mutate it (`appendStream`,
    /// `markCompleted`, ...).
    func addReview(
        prKey: String,
        repoFullName: String,
        prNumber: Int,
        headSha: String,
        headBranch: String
    ) -> Review {
        let review = Review(
            prKey: prKey,
            repoFullName: repoFullName,
            prNumber: prNumber,
            headSha: headSha,
            headBranch: headBranch,
            state: "running",
            startedAt: Date()
        )
        context.insert(review)
        try? context.save()
        return review
    }

    // MARK: - Streaming updates

    /// Append one chunk of streamed text to the review's partial buffer. Saves
    /// after each chunk so the modal can read live progress via SwiftData
    /// observation (slice 07's modal reads from in-memory state, but the save
    /// also means an app crash mid-review still leaves something visible).
    func appendStream(_ review: Review, text: String) {
        review.partialStream.append(text)
        try? context.save()
    }

    // MARK: - Terminal transitions

    /// Marks the review `completed`, sets `summary`/`verdict`/`rawResultJSON`
    /// from the decoded payload (when present), and inserts one `Finding`
    /// per `SchemaFinding`.
    ///
    /// `schema` may be nil when claude's structured payload could not be
    /// decoded against `ReviewSchema`. In that case `rawResultJSON` is still
    /// persisted (so the modal can show the raw output), `state` is still set
    /// to `completed` (the run finished), and `errorMessage` carries a flag
    /// noting the decode failure. This is the slice/07-fix tracer-bullet
    /// resilience contract — claude finished, the user gets to see it, even
    /// if the shape drifted.
    func markCompleted(_ review: Review, schema: ReviewSchema?, rawJSON: String) {
        review.state = "completed"
        review.finishedAt = Date()
        review.rawResultJSON = rawJSON

        guard let schema else {
            // Decode failed but the run finished. Surface raw output and
            // flag the failure via errorMessage; state stays `completed`.
            review.summary = nil
            review.verdict = nil
            review.errorMessage = "Schema decode failed — raw output below."
            try? context.save()
            return
        }

        review.summary = schema.summary
        review.verdict = schema.verdict
        review.errorMessage = nil

        for sf in schema.findings {
            let finding = Finding(
                severity: sf.normalizedSeverity,
                file: sf.file,
                line: sf.line,
                endLine: sf.endLine,
                title: sf.title,
                message: sf.message,
                suggestion: sf.suggestion,
                state: "open",
                review: review
            )
            context.insert(finding)
        }
        try? context.save()
    }

    /// Marks the review `failed` with the given stderr / decode error message.
    func markFailed(_ review: Review, error: String) {
        review.state = "failed"
        review.finishedAt = Date()
        review.errorMessage = error
        try? context.save()
    }

    /// Marks the review `timeout`. partialStream is preserved as-is so the user
    /// can still scroll back through whatever Claude produced before the kill.
    func markTimeout(_ review: Review) {
        review.state = "timeout"
        review.finishedAt = Date()
        review.errorMessage = "Review exceeded the 10-minute timeout."
        try? context.save()
    }

    // MARK: - Queries

    /// Returns the most recent review for the given `prKey` (any state), or nil
    /// if none. Slice 07 uses this to surface "last run" context if the user
    /// re-opens the modal for the same PR.
    func latestForPR(prKey: String) -> Review? {
        let descriptor = FetchDescriptor<Review>(
            predicate: #Predicate { $0.prKey == prKey },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor))?.first
    }
}
