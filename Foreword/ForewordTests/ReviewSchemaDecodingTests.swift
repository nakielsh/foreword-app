//
//  ReviewSchemaDecodingTests.swift
//  ForewordTests
//
//  Slice 07 — pure decode tests for `ReviewSchema` against fixture JSON.
//  Slice/07-fix added lenient field aliases (`overallAssessment` → `verdict`,
//  `description` → `message`, `suggestedFix` → `suggestion`), made `verdict`
//  optional, and added a severity normalization table. These tests pin both
//  the canonical-shape decode and the lenient real-world variants.
//
//  No URLSession, no SwiftData — just `JSONDecoder` + the wire types.
//

import XCTest
@testable import Foreword

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
        XCTAssertNil(decoded.category)
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

    // MARK: - slice/07-fix lenient aliases

    /// Real claude output uses `overallAssessment` instead of `verdict`.
    func testVerdictAliasOverallAssessment() throws {
        let json = """
        {
          "summary": "x",
          "overallAssessment": "needsWork",
          "findings": []
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.verdict, "needsWork")
    }

    /// `verdict` may be omitted entirely. Slice/07-fix made it optional.
    func testVerdictOmittedDecodesToNil() throws {
        let json = """
        {
          "summary": "x",
          "findings": []
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertNil(decoded.verdict)
        XCTAssertEqual(decoded.summary, "x")
    }

    /// `verdict` wins over `overallAssessment` when both are present.
    func testVerdictWinsOverOverallAssessment() throws {
        let json = """
        {
          "summary": "x",
          "verdict": "approve",
          "overallAssessment": "needsWork",
          "findings": []
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.verdict, "approve")
    }

    /// Real claude output uses `description` instead of `message`.
    func testFindingDescriptionAliasMapsToMessage() throws {
        let json = """
        {
          "severity": "high",
          "file": "f.swift",
          "line": 5,
          "title": "t",
          "description": "real description here"
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.message, "real description here")
    }

    /// Real claude output sometimes uses `issue` instead of `title`.
    func testFindingIssueAliasMapsToTitle() throws {
        let json = """
        {
          "severity": "minor",
          "file": "f.swift",
          "line": 5,
          "issue": "HTTP call inside transaction",
          "message": "m"
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.title, "HTTP call inside transaction")
    }

    /// Real claude output sometimes uses `explanation` instead of `message`.
    func testFindingExplanationAliasMapsToMessage() throws {
        let json = """
        {
          "severity": "minor",
          "file": "f.swift",
          "line": 5,
          "title": "t",
          "explanation": "HTTP calls hold the DB connection open during network latency."
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.message, "HTTP calls hold the DB connection open during network latency.")
    }

    /// Schema-side title/message win over alias keys when both are present.
    func testFindingTitleAndMessageWinOverAliases() throws {
        let json = """
        {
          "severity": "minor",
          "file": "f.swift",
          "line": 5,
          "title": "canonical title",
          "issue": "alias title",
          "message": "canonical message",
          "explanation": "alias message"
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.title, "canonical title")
        XCTAssertEqual(decoded.message, "canonical message")
    }

    /// Real claude output uses `suggestedFix` instead of `suggestion`.
    func testFindingSuggestedFixAliasMapsToSuggestion() throws {
        let json = """
        {
          "severity": "minor",
          "file": "f.swift",
          "line": 5,
          "title": "t",
          "message": "m",
          "suggestedFix": "do this instead"
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.suggestion, "do this instead")
    }

    /// `category` is captured when present.
    func testFindingCategoryCaptured() throws {
        let json = """
        {
          "severity": "critical",
          "category": "security",
          "file": "f.swift",
          "line": 5,
          "title": "t",
          "message": "m"
        }
        """
        let decoded = try decoder.decode(SchemaFinding.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.category, "security")
    }

    /// `positives` is captured when present.
    func testTopLevelPositivesArrayCaptured() throws {
        let json = """
        {
          "summary": "x",
          "verdict": "approve",
          "findings": [],
          "positives": ["good doc", "good tests"]
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.positives, ["good doc", "good tests"])
    }

    // MARK: - Severity normalization table

    /// Pin the severity-normalization mapping. Unknown values pass through
    /// unchanged so the UI can still display whatever claude said.
    func testSeverityNormalizationTable() {
        let cases: [(input: String, expected: String)] = [
            // 5-bucket canonical
            ("blocker",  "blocker"),
            ("major",    "major"),
            ("minor",    "minor"),
            ("nit",      "nit"),
            ("praise",   "praise"),
            // Common claude synonyms
            ("critical", "blocker"),
            ("high",     "major"),
            ("medium",   "minor"),
            ("low",      "nit"),
            ("info",     "nit"),
            ("nitpick",  "nit"),
            ("suggestion","nit"),
            // Case-insensitive
            ("CRITICAL", "blocker"),
            ("High",     "major"),
            ("Nitpick",  "nit"),
            // Unknown passes through unchanged
            ("trivial",  "trivial"),
            ("",         "")
        ]
        for c in cases {
            let f = SchemaFinding(
                severity: c.input,
                file: "x", line: 1,
                title: "t", message: "m"
            )
            XCTAssertEqual(
                f.normalizedSeverity, c.expected,
                "severity '\(c.input)' should normalize to '\(c.expected)'"
            )
        }
    }

    // MARK: - Real-world payload from user smoke test

    /// The exact payload shape that triggered the user's smoke-test failure.
    /// Renamed fields, `critical` severity, missing `verdict`, plus
    /// `positives`. Must round-trip cleanly with the lenient decoder.
    func testRealWorldClaudePayload() throws {
        let json = """
        {
          "summary": "Looks reasonable.",
          "overallAssessment": "needsWork",
          "findings": [
            {
              "file": "src/foo.swift",
              "line": 10,
              "severity": "critical",
              "category": "security",
              "title": "Plaintext password",
              "description": "Stored in plaintext; rotate to hashed.",
              "suggestedFix": "Use bcrypt(password)"
            }
          ],
          "positives": ["Good test coverage"]
        }
        """
        let decoded = try decoder.decode(ReviewSchema.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.summary, "Looks reasonable.")
        XCTAssertEqual(decoded.verdict, "needsWork")
        XCTAssertEqual(decoded.findings.count, 1)
        XCTAssertEqual(decoded.findings[0].severity, "critical")
        XCTAssertEqual(decoded.findings[0].normalizedSeverity, "blocker")
        XCTAssertEqual(decoded.findings[0].message, "Stored in plaintext; rotate to hashed.")
        XCTAssertEqual(decoded.findings[0].suggestion, "Use bcrypt(password)")
        XCTAssertEqual(decoded.findings[0].category, "security")
        XCTAssertEqual(decoded.positives, ["Good test coverage"])
    }
}
