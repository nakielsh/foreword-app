//
//  JiraBadgePresenceTests.swift
//  WorkHomepageTests
//
//  Slice 26 — Jira badge presence tests.
//
//  Exercises `JiraBadgeView.resolve(branchName:baseURL:)` — the pure static
//  helper — without a SwiftUI runtime. Covers the four acceptance-criteria
//  cases from the spec:
//    1. Valid branch + configured baseURL → (key, url) tuple.
//    2. Branch with no extractable key → nil.
//    3. Nil branch → nil.
//    4. baseURL unset → nil even when key is extractable.
//    5. Trailing slash on baseURL is collapsed (no double-slash in URL).
//

import XCTest
@testable import WorkHomepage

final class JiraBadgePresenceTests: XCTestCase {

    private let baseURL = "https://example.atlassian.net"

    // MARK: - Happy path

    func testResolvesKeyAndURLFromValidBranch() {
        let result = JiraBadgeView.resolve(
            branchName: "feature/JWT-123",
            baseURL: baseURL
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.key, "JWT-123")
        XCTAssertEqual(result?.url, URL(string: "https://example.atlassian.net/browse/JWT-123"))
    }

    func testAllSupportedPrefixesResolve() {
        let cases: [(branch: String, expectedKey: String)] = [
            ("bugfix/WEB-456", "WEB-456"),
            ("hotfix/AB-9", "AB-9"),
            ("chore/PROJ-100", "PROJ-100"),
            ("task/Z-1", "Z-1")
        ]
        for c in cases {
            let result = JiraBadgeView.resolve(branchName: c.branch, baseURL: baseURL)
            XCTAssertEqual(result?.key, c.expectedKey, "branch=\(c.branch)")
            XCTAssertEqual(
                result?.url,
                URL(string: "\(baseURL)/browse/\(c.expectedKey)"),
                "branch=\(c.branch)"
            )
        }
    }

    // MARK: - No key extractable

    func testReturnsNilForBranchWithNoKey() {
        let result = JiraBadgeView.resolve(branchName: "main", baseURL: baseURL)
        XCTAssertNil(result)
    }

    func testReturnsNilForFeatureBranchWithoutJiraKey() {
        let result = JiraBadgeView.resolve(branchName: "feature/add-logging", baseURL: baseURL)
        XCTAssertNil(result)
    }

    func testReturnsNilForDependabotBranch() {
        let result = JiraBadgeView.resolve(branchName: "dependabot/npm/lodash-4.17.21", baseURL: baseURL)
        XCTAssertNil(result)
    }

    // MARK: - Nil branch

    func testReturnsNilForNilBranch() {
        let result = JiraBadgeView.resolve(branchName: nil, baseURL: baseURL)
        XCTAssertNil(result)
    }

    // MARK: - Jira not configured

    func testReturnsNilWhenBaseURLIsNil() {
        let result = JiraBadgeView.resolve(branchName: "feature/JWT-123", baseURL: nil)
        XCTAssertNil(result)
    }

    func testReturnsNilWhenBaseURLIsEmpty() {
        let result = JiraBadgeView.resolve(branchName: "feature/JWT-123", baseURL: "")
        XCTAssertNil(result)
    }

    // MARK: - Trailing slash normalisation

    func testTrailingSlashOnBaseURLDoesNotDoubleSlashInURL() {
        let result = JiraBadgeView.resolve(
            branchName: "feature/JWT-123",
            baseURL: "https://example.atlassian.net/"
        )
        XCTAssertNotNil(result)
        let urlString = result?.url.absoluteString ?? ""
        XCTAssertFalse(urlString.contains("//browse"), "URL should not contain double-slash before /browse: \(urlString)")
        XCTAssertEqual(result?.url, URL(string: "https://example.atlassian.net/browse/JWT-123"))
    }

    func testMultipleTrailingSlashesNormalised() {
        let result = JiraBadgeView.resolve(
            branchName: "feature/JWT-123",
            baseURL: "https://example.atlassian.net///"
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.url, URL(string: "https://example.atlassian.net/browse/JWT-123"))
    }
}
