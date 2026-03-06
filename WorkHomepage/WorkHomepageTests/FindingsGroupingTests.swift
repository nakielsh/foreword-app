//
//  FindingsGroupingTests.swift
//  WorkHomepageTests
//
//  Slice 08 — pure unit tests for `FindingsGrouper.group(_:)`.
//
//  Verifies the bucket→display-order contract that the findings UI relies
//  on:
//   - Canonical severity values (`blocker`, `major`, `minor`, `nit`,
//     `praise`) appear in fixed order regardless of input order.
//   - Synonym values (`critical` → blocker, `high` → major, `medium` →
//     minor, `low` / `info` → nit) bucket into the canonical group.
//   - Truly novel severities (e.g. `weird`) collect into a trailing
//     `"other"` bucket so they aren't silently dropped.
//   - Empty buckets are not surfaced at all.
//   - Within a bucket, original input order is preserved.
//
//  These tests construct `Finding` rows directly without spinning up a
//  SwiftData container. `Finding` is a `@Model` class but its initialiser
//  works fine off-context — it just won't auto-persist, which is exactly
//  what we want here.
//

import XCTest
import SwiftData
@testable import WorkHomepage

final class FindingsGroupingTests: XCTestCase {

    // MARK: - Helper

    private func makeFinding(
        severity: String,
        title: String = "t",
        file: String = "f.swift",
        line: Int = 1
    ) -> Finding {
        return Finding(
            severity: severity,
            file: file,
            line: line,
            endLine: nil,
            title: title,
            message: "m",
            suggestion: nil,
            state: "open",
            review: nil
        )
    }

    // MARK: - Order contract

    func testGroupsCanonicalSeveritiesInFixedOrder() {
        // Inputs deliberately out of display order.
        let findings: [Finding] = [
            makeFinding(severity: "praise", title: "P1"),
            makeFinding(severity: "blocker", title: "B1"),
            makeFinding(severity: "nit", title: "N1"),
            makeFinding(severity: "major", title: "M1"),
            makeFinding(severity: "minor", title: "Mi1"),
        ]

        let sections = FindingsGrouper.group(findings)
        let order = sections.map { $0.severity }
        XCTAssertEqual(order, ["blocker", "major", "minor", "nit", "praise"])
    }

    // MARK: - Empty buckets dropped

    func testEmptyBucketsAreOmitted() {
        let findings: [Finding] = [
            makeFinding(severity: "blocker"),
            makeFinding(severity: "praise"),
        ]
        let sections = FindingsGrouper.group(findings)
        XCTAssertEqual(sections.map { $0.severity }, ["blocker", "praise"])
    }

    // MARK: - Synonym normalisation

    func testSynonymsBucketIntoCanonicalGroup() {
        // Mix raw severities — `critical` → blocker, `high` → major,
        // `medium` → minor, `low`/`info` → nit. The grouper should fold all
        // of these into the canonical buckets.
        let findings: [Finding] = [
            makeFinding(severity: "critical", title: "C1"),
            makeFinding(severity: "blocker",  title: "B1"),
            makeFinding(severity: "high",     title: "H1"),
            makeFinding(severity: "medium",   title: "Md1"),
            makeFinding(severity: "low",      title: "L1"),
            makeFinding(severity: "info",     title: "I1"),
        ]

        let sections = FindingsGrouper.group(findings)
        let bySeverity = Dictionary(uniqueKeysWithValues: sections.map { ($0.severity, $0.items) })

        XCTAssertEqual(bySeverity["blocker"]?.count, 2)
        XCTAssertEqual(bySeverity["major"]?.count, 1)
        XCTAssertEqual(bySeverity["minor"]?.count, 1)
        XCTAssertEqual(bySeverity["nit"]?.count, 2)
        XCTAssertNil(bySeverity["praise"])
    }

    // MARK: - Unknown severity → "other"

    func testUnknownSeveritiesFallIntoOtherBucket() {
        let findings: [Finding] = [
            makeFinding(severity: "blocker", title: "B1"),
            makeFinding(severity: "weird",   title: "W1"),
            makeFinding(severity: "alien",   title: "A1"),
        ]

        let sections = FindingsGrouper.group(findings)
        XCTAssertEqual(sections.map { $0.severity }, ["blocker", "other"])
        let other = sections.first(where: { $0.severity == "other" })
        XCTAssertEqual(other?.items.count, 2)
    }

    // MARK: - Within-bucket order preserved

    func testInputOrderPreservedWithinBucket() {
        let findings: [Finding] = [
            makeFinding(severity: "blocker", title: "First"),
            makeFinding(severity: "major",   title: "Mid"),
            makeFinding(severity: "blocker", title: "Second"),
            makeFinding(severity: "blocker", title: "Third"),
        ]

        let sections = FindingsGrouper.group(findings)
        let blocker = sections.first(where: { $0.severity == "blocker" })
        XCTAssertEqual(blocker?.items.map { $0.title }, ["First", "Second", "Third"])
    }

    // MARK: - Empty input

    func testEmptyInputReturnsNoSections() {
        let sections = FindingsGrouper.group([])
        XCTAssertTrue(sections.isEmpty)
    }

    // MARK: - Case-insensitive matching

    func testSeverityMatchingIsCaseInsensitive() {
        let findings: [Finding] = [
            makeFinding(severity: "BLOCKER"),
            makeFinding(severity: "Major"),
            makeFinding(severity: "Critical"),
        ]
        let sections = FindingsGrouper.group(findings)
        let bySeverity = Dictionary(uniqueKeysWithValues: sections.map { ($0.severity, $0.items.count) })
        XCTAssertEqual(bySeverity["blocker"], 2)
        XCTAssertEqual(bySeverity["major"], 1)
    }
}
