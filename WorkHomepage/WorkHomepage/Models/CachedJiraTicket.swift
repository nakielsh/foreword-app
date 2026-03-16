//
//  CachedJiraTicket.swift
//  WorkHomepage
//
//  Slice 12 — Jira ticket cache.
//
//  SwiftData persistence shadow of the value-type `JiraTicket`. We store one
//  row per Jira issue key and use the freshness timestamp Jira returns under
//  the `updated` field as the cache key. String comparison is fine —
//  Atlassian Cloud emits stable ISO-8601-ish timestamps and we never need to
//  compare two of them semantically, only for equality.
//
//  `descriptionText` is already plaintext (ADF flattened by `JiraClient`), so
//  we never store ADF. `parentKey` is preserved when present so parent
//  recovery on cache hits doesn't have to refetch the full subtask just to
//  learn its parent. The parent ticket itself is NOT modeled as a
//  relationship — parents and subtasks are flat rows here, and `JiraClient`
//  reconstructs the one-level parent attachment by looking up `parentKey`
//  against the cache.
//
//  Optional Jira fields (`priority`, `parentKey`) are stored as empty
//  strings and translated at the cache boundary by `JiraClient.Cache`.
//
//  Land-mine: the freshness timestamp lives under `updatedAt`, NOT
//  `updated`. NSManagedObject (which @Model classes inherit from at
//  runtime) declares its own `updated` selector — a Bool that means "this
//  object has unsaved changes" — and a String-typed `updated` property on
//  the SwiftData model collides with that selector during save, surfacing
//  as `swift_dynamicCast` aborts inside `NSManagedObjectContext`.
//

import Foundation
import SwiftData

@Model
final class CachedJiraTicket {
    /// Stable id used as primary key. Distinct from `key` so the latter can
    /// stay a domain-meaningful string while the SwiftData unique constraint
    /// rides on a UUID — the same shape the codebase uses for `Review` and
    /// `Finding`.
    @Attribute(.unique) var id: UUID

    /// Jira issue key, e.g. `"JWT-123"`. Looked up via predicate in
    /// `JiraClient.Cache`; not unique-attributed at the schema level
    /// because the upsert helper handles dedup itself.
    var key: String

    var summary: String

    /// Already-plaintext description (ADF flattened by `JiraClient`). The
    /// name dodges the ObjC `description` clash that NSObject injects.
    var descriptionText: String

    var status: String
    var issueType: String

    /// Empty string when Jira reported no priority. Translated to `nil`
    /// when handed back to callers as a `JiraTicket`.
    var priority: String

    /// Parent issue key when this row represents a subtask. Empty when the
    /// ticket has no parent.
    var parentKey: String

    /// Raw `updated` timestamp from Jira (e.g.
    /// `"2026-05-08T11:42:33.000+0000"`). Named `updatedAt` rather than
    /// `updated` to avoid the NSManagedObject selector clash described in
    /// the file header.
    var updatedAt: String

    /// When we last wrote this row. Currently informational, but useful for
    /// future eviction policies (slice 17 disk-usage).
    var fetchedAt: Date

    init(
        id: UUID = UUID(),
        key: String,
        summary: String,
        descriptionText: String,
        status: String,
        issueType: String,
        priority: String?,
        parentKey: String?,
        updated: String
    ) {
        self.id = id
        self.key = key
        self.summary = summary
        self.descriptionText = descriptionText
        self.status = status
        self.issueType = issueType
        self.priority = priority ?? ""
        self.parentKey = parentKey ?? ""
        self.updatedAt = updated
        self.fetchedAt = Date()
    }
}
