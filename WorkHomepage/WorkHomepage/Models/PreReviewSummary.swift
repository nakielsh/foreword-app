//
//  PreReviewSummary.swift
//  WorkHomepage
//
//  Slice 24 — Pre-Review Summary tracer.
//
//  SwiftData model for the lightweight 3-bullet TL;DR produced by the
//  Pre-Review Summary pipeline. Keyed by `(prKey, headSha)` so each commit
//  gets its own cached row. The unique constraint is on the composite `id`
//  field, which is `"\(prKey)|\(headSha)"`.
//
//  Distinct from `Review`: no worktree, no findings, no verdict. Just
//  what/why/risk for use as decision support on the card.
//

import Foundation
import SwiftData

@Model
final class PreReviewSummary {
    /// Composite unique identifier: `"\(prKey)|\(headSha)"`.
    @Attribute(.unique) var id: String

    /// `<org>/<repo>#<number>` — stable key matching `Review.prKey`.
    var prKey: String

    /// PR head commit SHA at the time of the summary. A new commit invalidates
    /// the cache by producing a row with a new `id`.
    var headSha: String

    /// One sentence: what changed.
    var what: String

    /// One sentence: why this change is happening.
    var why: String

    /// One sentence: regressions / footguns / areas to scrutinize.
    var risk: String

    /// When this summary was generated.
    var generatedAt: Date

    init(
        prKey: String,
        headSha: String,
        what: String,
        why: String,
        risk: String,
        generatedAt: Date
    ) {
        self.id = "\(prKey)|\(headSha)"
        self.prKey = prKey
        self.headSha = headSha
        self.what = what
        self.why = why
        self.risk = risk
        self.generatedAt = generatedAt
    }
}
