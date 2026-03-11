//
//  JiraTicket.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//  Slice 11 — adds optional `parent: JiraTicket?` for the subtask
//  parent-fallback story.
//
//  Plain value type used to inject Jira context into the review prompt.
//  Not a SwiftData @Model — slice 12 introduces a persisted version for
//  caching. Until then we re-fetch on every review.
//
//  Fields mirror what the orchestrator embeds in the prompt block:
//  summary, status, issue type, optional priority, the ADF-flattened
//  description, the optional parent key (always populated when the
//  ticket itself is a subtask in Jira), and the optional `parent`
//  ticket — populated only when `JiraClient` decided the subtask's own
//  description was too thin and fetched the parent in. `parent` is
//  recursive but **one level only** by construction in `JiraClient`.
//
//  Recursion is implemented through an `indirect` enum (`ParentBox`) so
//  the value-type layout stays well-defined. Callers see `parent` as an
//  ordinary `JiraTicket?` — the boxing is private. Codable + Hashable
//  use the unwrapped `parent`, so JSON snapshots stay flat ("parent": …).
//

import Foundation

struct JiraTicket {
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

    /// Internal storage — `indirect` enum gives the compiler a finite,
    /// heap-allocated layout for the recursive case. Public access goes
    /// through the `parent` computed property below.
    private let parentBox: ParentBox

    /// Populated only when this ticket is a subtask whose own description was
    /// too thin to stand alone, and `JiraClient` fetched the parent. The
    /// parent here will itself always have `parent == nil` — we never
    /// recurse past one level.
    var parent: JiraTicket? {
        switch parentBox {
        case .none:
            return nil
        case .some(let ticket):
            return ticket
        }
    }

    init(
        key: String,
        summary: String,
        description: String,
        status: String,
        issueType: String,
        priority: String?,
        parentKey: String?,
        parent: JiraTicket? = nil
    ) {
        self.key = key
        self.summary = summary
        self.description = description
        self.status = status
        self.issueType = issueType
        self.priority = priority
        self.parentKey = parentKey
        if let parent {
            self.parentBox = .some(parent)
        } else {
            self.parentBox = .none
        }
    }

    // MARK: - Recursive storage

    /// `indirect` makes the recursive case heap-allocated, which gives
    /// `JiraTicket` a fixed-size layout. Without this the compiler would
    /// face an infinite-size struct.
    private indirect enum ParentBox {
        case none
        case some(JiraTicket)
    }
}

// MARK: - Hashable

extension JiraTicket: Hashable {
    static func == (lhs: JiraTicket, rhs: JiraTicket) -> Bool {
        lhs.key == rhs.key
            && lhs.summary == rhs.summary
            && lhs.description == rhs.description
            && lhs.status == rhs.status
            && lhs.issueType == rhs.issueType
            && lhs.priority == rhs.priority
            && lhs.parentKey == rhs.parentKey
            && lhs.parent == rhs.parent
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(summary)
        hasher.combine(description)
        hasher.combine(status)
        hasher.combine(issueType)
        hasher.combine(priority)
        hasher.combine(parentKey)
        hasher.combine(parent)
    }
}

// MARK: - Codable

extension JiraTicket: Codable {
    private enum CodingKeys: String, CodingKey {
        case key, summary, description, status, issueType, priority, parentKey, parent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        let summary = try container.decode(String.self, forKey: .summary)
        let description = try container.decode(String.self, forKey: .description)
        let status = try container.decode(String.self, forKey: .status)
        let issueType = try container.decode(String.self, forKey: .issueType)
        let priority = try container.decodeIfPresent(String.self, forKey: .priority)
        let parentKey = try container.decodeIfPresent(String.self, forKey: .parentKey)
        let parent = try container.decodeIfPresent(JiraTicket.self, forKey: .parent)
        self.init(
            key: key,
            summary: summary,
            description: description,
            status: status,
            issueType: issueType,
            priority: priority,
            parentKey: parentKey,
            parent: parent
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(summary, forKey: .summary)
        try container.encode(description, forKey: .description)
        try container.encode(status, forKey: .status)
        try container.encode(issueType, forKey: .issueType)
        try container.encodeIfPresent(priority, forKey: .priority)
        try container.encodeIfPresent(parentKey, forKey: .parentKey)
        try container.encodeIfPresent(parent, forKey: .parent)
    }
}
