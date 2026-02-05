//
//  DeploymentsParserTests.swift
//  WorkHomepageTests
//
//  Slice 05: table-driven tests for `DeploymentsParser.parse(runName:)`.
//  Mirrors the regex from index.html:
//      /^\[(\w+)\]\s+Deploy\s+v?([\S]+?)(?:\s+apply|$)/i
//

import XCTest
@testable import WorkHomepage

final class DeploymentsParserTests: XCTestCase {

    private struct Case {
        let name: String
        let input: String
        let expected: DeploymentsParser.ParsedRun?
        let file: StaticString
        let line: UInt

        init(_ name: String, _ input: String, _ expected: DeploymentsParser.ParsedRun?, file: StaticString = #file, line: UInt = #line) {
            self.name = name
            self.input = input
            self.expected = expected
            self.file = file
            self.line = line
        }
    }

    func testParseTable() {
        let cases: [Case] = [
            Case(
                "dev with snapshot suffix and trailing prose",
                "[dev] Deploy v1.21.1-feature-xyz-snapshot",
                .init(env: "dev", version: "1.21.1-feature-xyz-snapshot")
            ),
            Case(
                "prod release",
                "[prod] Deploy v1.21.1",
                .init(env: "prod", version: "1.21.1")
            ),
            Case(
                "prod release with `apply` suffix is stripped",
                "[prod] Deploy v1.21.1 apply w/out WAF",
                .init(env: "prod", version: "1.21.1")
            ),
            Case(
                "case-insensitive Deploy keyword",
                "[Dev] deploy v1.0.0",
                .init(env: "dev", version: "1.0.0")
            ),
            Case(
                "version without leading v is accepted",
                "[prod] Deploy 1.0.0",
                .init(env: "prod", version: "1.0.0")
            ),
            Case(
                "no env tag returns nil",
                "Deploy v1.0.0",
                nil
            ),
            Case(
                "empty input returns nil",
                "",
                nil
            ),
            Case(
                "malformed brackets return nil",
                "[dev Deploy v1.0.0",
                nil
            ),
            Case(
                "env present but no version returns nil",
                "[prod] Deploy",
                nil
            ),
            Case(
                "env tag but unrelated body returns nil",
                "[dev] Build something",
                nil
            ),
            Case(
                "snapshot version with apply trailing",
                "[dev] Deploy v1.21.1-feature-jwt-943-snapshot apply w/out WAF",
                .init(env: "dev", version: "1.21.1-feature-jwt-943-snapshot")
            ),
        ]

        for c in cases {
            let result = DeploymentsParser.parse(runName: c.input)
            XCTAssertEqual(
                result,
                c.expected,
                "Case [\(c.name)] expected \(String(describing: c.expected)) but got \(String(describing: result)) for input: \(c.input)",
                file: c.file,
                line: c.line
            )
        }
    }

    func testEnvIsLowercased() {
        let result = DeploymentsParser.parse(runName: "[PROD] Deploy v2.0.0")
        XCTAssertEqual(result?.env, "prod")
        XCTAssertEqual(result?.version, "2.0.0")
    }
}
