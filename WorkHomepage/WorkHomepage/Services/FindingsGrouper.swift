//
//  FindingsGrouper.swift
//  WorkHomepage
//
//  Slice 08 — Findings UI.
//
//  Pure helper that buckets `Finding` rows into severity sections in the
//  fixed display order `blocker → major → minor → nit → praise`, with any
//  unknown-severity rows folded into a trailing `other` bucket so claude's
//  occasional novel severity strings still surface in the UI rather than
//  being dropped on the floor.
//
//  Lives outside `ReviewSheet.swift` so the grouping logic can be unit-tested
//  without spinning up SwiftUI.
//
//  The `severity` field on `Finding` is already normalised at persistence
//  time (`ReviewStore.markCompleted` stores `SchemaFinding.normalizedSeverity`),
//  so we treat it as already-canonical here. Severities outside the 5-bucket
//  vocabulary still exist, however — `normalizedSeverity` returns the raw
//  string verbatim when it doesn't recognise it — so the grouper does its
//  own bucket lookup rather than assuming canonical inputs.
//

import Foundation

enum FindingsGrouper {

    /// Display order for severity sections. The UI renders sections in this
    /// order, skipping empty ones. Anything that doesn't match falls into
    /// `"other"` and is appended last.
    static let severityOrder: [String] = ["blocker", "major", "minor", "nit", "praise"]

    /// One severity bucket. `severity` is the canonical key (`"blocker"`,
    /// `"major"`, …, or `"other"` for unknowns); `items` is the findings in
    /// that bucket, preserving input order.
    struct Section: Equatable {
        let severity: String
        let items: [Finding]
    }

    /// Groups findings by severity, in display order. Empty buckets are
    /// dropped. Findings whose normalised severity isn't one of the 5
    /// canonical values are collected into a trailing `"other"` section.
    ///
    /// Input order within each bucket is preserved — the orchestrator hands
    /// findings to `ReviewStore.markCompleted` in the order claude returned
    /// them, and that's the order we want to render.
    static func group(_ findings: [Finding]) -> [Section] {
        var buckets: [String: [Finding]] = [:]
        var otherKeys: [String] = []  // first-seen order of unknown severities

        for finding in findings {
            let key = canonicalKey(for: finding.severity)
            if buckets[key] == nil {
                buckets[key] = []
                if !severityOrder.contains(key) && !otherKeys.contains(key) {
                    otherKeys.append(key)
                }
            }
            buckets[key]?.append(finding)
        }

        var sections: [Section] = []
        for key in severityOrder {
            if let items = buckets[key], !items.isEmpty {
                sections.append(Section(severity: key, items: items))
            }
        }
        // Fold any unknown-severity buckets into a single `"other"` section,
        // preserving first-seen order across them.
        var otherItems: [Finding] = []
        for key in otherKeys {
            if let items = buckets[key] {
                otherItems.append(contentsOf: items)
            }
        }
        if !otherItems.isEmpty {
            sections.append(Section(severity: "other", items: otherItems))
        }
        return sections
    }

    /// Maps a raw severity string to the canonical bucket. Mirrors
    /// `SchemaFinding.normalizedSeverity` so we can group `Finding` rows
    /// (which only carry the post-normalisation severity) consistently with
    /// what claude originally emitted, and so unrecognised values still find
    /// a stable home.
    private static func canonicalKey(for raw: String) -> String {
        switch raw.lowercased() {
        case "blocker", "critical": return "blocker"
        case "major", "high":       return "major"
        case "minor", "medium":     return "minor"
        case "nit", "low", "info":  return "nit"
        case "praise":              return "praise"
        default:                    return raw.lowercased()
        }
    }
}
