//
//  ReviewSchemaDecodingTests.swift
//  WorkHomepageTests
//
//  Slice 07 — pure decode tests for `ReviewSchema` against fixture JSON.
//  Covers: full payload, null `jira_alignment`, missing `endLine` and
//  `suggestion`, missing `jira_alignment` entirely, and verdict variants.
//
//  No URLSession, no SwiftData — just `JSONDecoder` + the wire types.
//

import XCTest
@testable import WorkHomepage

final class ReviewSchemaDecodingTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - Full payload (all fields populated)

    func testDecodesFullPayload() throws {
        let json = """
        {
          "summary": "Looks good with two minor nits.",
          "verdict": "comment",
          "findings": [
            {
              "severity": "minor",
              "file": "src/foo/Bar.swift",
              "line": 42,
              "endLine": 50,
              "title": "Force-unwrap on optional",
              "message": "This crashes on cold start. Use guard let instead.",
              "suggestion": "guard let x = optional else { return }"
            },
            {
              "severity": "praise",
              "file": "README.md",
              "line": 1,
              "endLine": null,
              "title": "Nice docstring",
              "message": "Clear intro.",
              "suggestion": null
            }
          ],
          "jira_alignment": {
            "matches_ticket": true,
            "notes": "Implements ABC-123 as described."
          }
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.summary, "Looks good with two minor nits.")
        XCTAssertEqual(decoded.verdict, "comment")
        XCTAssertEqual(decoded.findings.count, 2)
        XCTAssertEqual(decoded.findings[0].severity, "minor")
        XCTAssertEqual(decoded.findings[0].file, "src/foo/Bar.swift")
        XCTAssertEqual(decoded.findings[0].line, 42)
        XCTAssertEqual(decoded.findings[0].endLine, 50)
        XCTAssertEqual(decoded.findings[0].suggestion, "guard let x = optional else { return }")
        XCTAssertNil(decoded.findings[1].endLine)
        XCTAssertNil(decoded.findings[1].suggestion)
        XCTAssertEqual(decoded.jiraAlignment?.matchesTicket, true)
        XCTAssertEqual(decoded.jiraAlignment?.notes, "Implements ABC-123 as described.")
    }

    // MARK: - jira_alignment is null

    func testDecodesWithNullJiraAlignment() throws {
        let json = """
        {
          "summary": "No Jira context.",
          "verdict": "approve",
          "findings": [],
          "jira_alignment": null
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.summary, "No Jira context.")
        XCTAssertEqual(decoded.verdict, "approve")
        XCTAssertTrue(decoded.findings.isEmpty)
        XCTAssertNil(decoded.jiraAlignment)
    }

    // MARK: - jira_alignment field absent entirely

    func testDecodesWithMissingJiraAlignment() throws {
        let json = """
        {
          "summary": "Ship it.",
          "verdict": "approve",
          "findings": []
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertNil(decoded.jiraAlignment)
        XCTAssertEqual(decoded.verdict, "approve")
    }

    // MARK: - findings missing optional fields

    func testFindingMissingOptionals() throws {
        let json = """
        {
          "severity": "blocker",
          "file": "src/Crash.swift",
          "line": 1,
          "title": "NPE",
          "message": "Will crash."
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.severity, "blocker")
        XCTAssertEqual(decoded.line, 1)
        XCTAssertNil(decoded.endLine)
        XCTAssertNil(decoded.suggestion)
    }

    // MARK: - jira_alignment partial (only notes)

    func testJiraAlignmentOnlyNotes() throws {
        let json = """
        {
          "summary": "...",
          "verdict": "request_changes",
          "findings": [],
          "jira_alignment": { "notes": "Could not determine — no ticket key in branch." }
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertNil(decoded.jiraAlignment?.matchesTicket)
        XCTAssertEqual(decoded.jiraAlignment?.notes, "Could not determine — no ticket key in branch.")
    }

    // MARK: - Verdict round-trips as String

    func testVerdictsRoundTrip() throws {
        for verdict in ["approve", "request_changes", "comment"] {
            let json = """
            { "summary": "x", "verdict": "\(verdict)", "findings": [] }
            """
            let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
            XCTAssertEqual(decoded.verdict, verdict)
        }
    }
}
