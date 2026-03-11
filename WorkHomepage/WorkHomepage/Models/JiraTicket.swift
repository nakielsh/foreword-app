//
//  JiraTicket.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//
//  Plain value type used to inject Jira context into the review prompt.
//  Not a SwiftData @Model — slice 12 introduces a persisted version for
//  caching. Until then we re-fetch on every review.
//
//  Fields mirror what the orchestrator embeds in the prompt block:
//  summary, status, issue type, optional priority, the ADF-flattened
//  description, and the optional parent key (slice 11 uses parent for the
//  no-ticket-fallback story; slice 10 just records it).
//

import Foundation

struct JiraTicket: Codable, Hashable {
    let key: String
    let summary: String
    /// ADF flattened to plaintext. Paragraph / heading / list-item boundaries
    /// become `\n\n` separators; inline marks (bold, italic, …) collapse to
    /// the underlying text.
    let description: String
    let status: String
    let issueType: String
    let priority: String?
    let parentKey: String?
}
