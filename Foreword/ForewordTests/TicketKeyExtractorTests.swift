//
//  TicketKeyExtractorTests.swift
//  ForewordTests
//
//  Slice 10. Table-driven cases for the head-branch → Jira-key parser.
//  Covers all five branch prefixes from the PRD (feature/bugfix/hotfix/
//  chore/task), trunk branches (main, master), dependabot branches, free
//  feature branches, mid-string keys, and "first match wins" when the
//  branch name has noise after the key.
//

import XCTest
@testable import Foreword

final class TicketKeyExtractorTests: XCTestCase {

    func testExtractsKeyForAllPrefixes() {
        let cases: [(branch: String, expected: String?)] = [
            ("feature/PROJ-123", "PROJ-123"),
            ("bugfix/PROJ-456", "PROJ-456"),
            ("hotfix/AB-9999", "AB-9999"),
            ("chore/X-1", "X-1"),
            ("task/Z-42", "Z-42")
        ]
        for c in cases {
            XCTAssertEqual(
                TicketKeyExtractor.extract(branchName: c.branch),
                c.expected,
                "branch=\(c.branch)"
            )
        }
    }

    func testReturnsNilForBranchesWithoutPrefix() {
        for branch in ["main", "master", "PROJ-123"] {
            XCTAssertNil(
                TicketKeyExtractor.extract(branchName: branch),
                "branch=\(branch)"
            )
        }
    }

    func testReturnsNilForFeaturePrefixWithoutKey() {
        XCTAssertNil(TicketKeyExtractor.extract(branchName: "feature/whatever"))
    }

    func testReturnsNilForDependabotBranch() {
        XCTAssertNil(TicketKeyExtractor.extract(branchName: "dependabot/npm/foo"))
    }

    func testFirstMatchWinsWhenSuffixPresent() {
        XCTAssertEqual(
            TicketKeyExtractor.extract(branchName: "feature/PROJ-123-something"),
            "PROJ-123"
        )
    }

    func testEmptyStringReturnsNil() {
        XCTAssertNil(TicketKeyExtractor.extract(branchName: ""))
    }

    func testLowerCaseProjectKeyDoesNotMatch() {
        // Jira keys are uppercase by convention; lowercase keys should not
        // be auto-promoted (we want the user to see the canonical key).
        XCTAssertNil(TicketKeyExtractor.extract(branchName: "feature/proj-123"))
    }

    func testReleaseBranchDoesNotMatch() {
        XCTAssertNil(TicketKeyExtractor.extract(branchName: "release/2026-05-08"))
    }

    func testMultiNumericKeyExtracted() {
        XCTAssertEqual(
            TicketKeyExtractor.extract(branchName: "task/PROJ-1000000"),
            "PROJ-1000000"
        )
    }

    func testKeyAfterSlashOnlyMatchesImmediateSegment() {
        // A nested path under feature/ should not match because the regex
        // is anchored to feature/ followed immediately by the key.
        XCTAssertNil(TicketKeyExtractor.extract(branchName: "feature/sub/PROJ-123"))
    }
}
