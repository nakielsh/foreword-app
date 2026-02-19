//
//  Review.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  SwiftData model representing a single Claude review run for a given PR head SHA.
//  Slice 07 enforces single-flight, so at most one row will be `running` at a time.
//  The state machine is `running -> completed | failed | timeout`. Cancelled is
//  reserved for slice 13.
//
//  `partialStream` accumulates every text delta we receive from claude's stream-json
//  output, so that even on failure / timeout the user can read what we got. This is
//  what slice 07's modal renders live during the run.
//
//  `rawResultJSON` holds the final structured `result` payload, pretty-printed,
//  for slice 07's "raw display" of findings. Slice 08 decodes the same payload and
//  styles findings, but persisting both `Findings` rows AND the raw JSON keeps
//  this slice's UI cheap while still feeding slice 08's data path.
//

import Foundation
import SwiftData

@Model
final class Review {
    /// Stable id used as primary key. Distinct from SwiftData's `persistentModelID`
    /// so we can build dictionary keys / refer to a row by UUID outside the context.
    @Attribute(.unique) var id: UUID

    /// `<org>/<repo>#<number>` — convenience grouping key for "all reviews of PR X".
    var prKey: String

    /// `<org>/<repo>` — used by WorktreeManager and the Review button to know which
    /// repo to clone / fetch.
    var repoFullName: String

    /// PR number as on GitHub (1-based).
    var prNumber: Int

    /// PR head commit SHA at the moment we kicked off the review.
    /// Slice 14 keys versions on this; slice 07 just records it.
    var headSha: String

    /// PR head branch name (e.g. `feature/JWT-123`).
    var headBranch: String

    /// One of `running`, `completed`, `failed`, `timeout`.
    /// Stored as a String rather than an enum to keep the SwiftData migration
    /// surface trivial as later slices add states (`queued`, `cancelled`).
    var state: String

    /// When the review was created. Set at `running` time.
    var startedAt: Date

    /// When the review reached a terminal state. nil while `running`.
    var finishedAt: Date?

    /// Top-level summary parsed out of the final structured payload. nil until
    /// `completed`.
    var summary: String?

    /// `approve | request_changes | comment` — verdict from Claude's structured
    /// payload. nil until `completed`.
    var verdict: String?

    /// Jira ticket key used in this review. Always nil in slice 07
    /// (slice 10 wires Jira). Field present early so the SwiftData store layout
    /// doesn't change later.
    var jiraKey: String?

    /// stderr or decode error captured when state transitions to `failed` or
    /// `timeout`. nil for `running` / `completed`.
    var errorMessage: String?

    /// Concatenated text deltas streamed by claude. Populated incrementally
    /// during the run so the modal can show live progress, then persisted as
    /// part of the terminal-state save.
    var partialStream: String

    /// Final `result` event payload from claude, pretty-printed JSON. Slice 07's
    /// modal renders this raw; slice 08 decodes it for styled findings.
    var rawResultJSON: String?

    /// Findings parsed from the final structured payload. Cascade-deleted when
    /// the review row is deleted. Slice 07 persists them so slice 08's UI just
    /// reads from the store.
    @Relationship(deleteRule: .cascade, inverse: \Finding.review)
    var findings: [Finding] = []

    init(
        id: UUID = UUID(),
        prKey: String,
        repoFullName: String,
        prNumber: Int,
        headSha: String,
        headBranch: String,
        state: String = "running",
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        summary: String? = nil,
        verdict: String? = nil,
        jiraKey: String? = nil,
        errorMessage: String? = nil,
        partialStream: String = "",
        rawResultJSON: String? = nil
    ) {
        self.id = id
        self.prKey = prKey
        self.repoFullName = repoFullName
        self.prNumber = prNumber
        self.headSha = headSha
        self.headBranch = headBranch
        self.state = state
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.summary = summary
        self.verdict = verdict
        self.jiraKey = jiraKey
        self.errorMessage = errorMessage
        self.partialStream = partialStream
        self.rawResultJSON = rawResultJSON
    }
}
