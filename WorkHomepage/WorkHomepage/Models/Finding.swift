//
//  Finding.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  One issue/observation produced by Claude inside a Review's structured payload.
//  Persisted in slice 07 (so slice 08's findings UI can just read SwiftData) but
//  not displayed yet — slice 07's modal renders the raw JSON.
//
//  `state` is `open` for slice 07. Slice 08 wires `resolved` / `dismissed` plus
//  filters in the UI.
//

import Foundation
import SwiftData

@Model
final class Finding {
    /// Stable id used as primary key. Distinct from `persistentModelID` for the
    /// same reason `Review.id` is — lets us refer to findings outside the
    /// SwiftData context (e.g. "mark resolved" in slice 08).
    @Attribute(.unique) var id: UUID

    /// `blocker | major | minor | nit | praise`.
    var severity: String

    /// Path relative to the PR's repo root.
    var file: String

    /// 1-based line where the finding starts.
    var line: Int

    /// Optional 1-based end line for multi-line findings.
    var endLine: Int?

    /// One-line headline.
    var title: String

    /// 1-3 sentence description of the issue.
    var message: String

    /// Optional code-level suggestion. Nil when Claude didn't provide one.
    var suggestion: String?

    /// `open | resolved | dismissed`. Slice 07 only ever writes `open`.
    /// Slice 08 owns the resolved/dismissed transitions and the hide-by-default
    /// filter.
    var state: String

    /// Back-reference to the parent review. Reverse relationship is on
    /// `Review.findings` with cascade delete, so deleting a Review takes its
    /// Findings with it.
    var review: Review?

    init(
        id: UUID = UUID(),
        severity: String,
        file: String,
        line: Int,
        endLine: Int? = nil,
        title: String,
        message: String,
        suggestion: String? = nil,
        state: String = "open",
        review: Review? = nil
    ) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.endLine = endLine
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.state = state
        self.review = review
    }
}
