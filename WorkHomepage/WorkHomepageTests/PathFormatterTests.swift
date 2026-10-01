//
//  PathFormatterTests.swift
//  WorkHomepageTests
//
//  Table-driven coverage for the home-prefix splitter used by SessionsTab.
//

import XCTest
@testable import WorkHomepage

final class PathFormatterTests: XCTestCase {

    func testAbbreviateHomeTableDriven() {
        struct Case {
            let input: String
            let expectedPrefix: String
            let expectedRest: String
            let line: UInt
        }

        let cases: [Case] = [
            Case(input: "/Users/foo/bar/baz",
                 expectedPrefix: "~",
                 expectedRest: "/bar/baz",
                 line: #line),
            Case(input: "/etc/foo",
                 expectedPrefix: "",
                 expectedRest: "/etc/foo",
                 line: #line),
            Case(input: "/Users/foo",
                 expectedPrefix: "~",
                 expectedRest: "",
                 line: #line),
            Case(input: "",
                 expectedPrefix: "",
                 expectedRest: "",
                 line: #line),
            // Defensive extras — ensure realistic dev paths split sensibly.
            Case(input: "/Users/jane/src/widgets",
                 expectedPrefix: "~",
                 expectedRest: "/src/widgets",
                 line: #line),
            Case(input: "/Users/",
                 expectedPrefix: "",
                 expectedRest: "/Users/",
                 line: #line),
        ]

        for c in cases {
            let result = PathFormatter.abbreviateHome(c.input)
            XCTAssertEqual(result.prefix, c.expectedPrefix,
                           "prefix mismatch for input \(c.input)", line: c.line)
            XCTAssertEqual(result.rest, c.expectedRest,
                           "rest mismatch for input \(c.input)", line: c.line)
        }
    }
}
