//
//  PromptInterpolatorTests.swift
//  WorkHomepageTests
//
//  Slice 23 — Custom Review Prompt Template.
//
//  Table-driven tests for `PromptInterpolator`. Covers known-variable
//  substitution, unknown-variable passthrough, repeated tokens, whitespace
//  inside braces, malformed delimiters, empty template, and
//  `unknownVariables` deduplication + ordering.
//

import XCTest
@testable import WorkHomepage

final class PromptInterpolatorTests: XCTestCase {

    // MARK: - interpolate: known variables

    func testKnownVariableIsReplaced() {
        let result = PromptInterpolator.interpolate("Hello {{name}}!", vars: ["name": "World"])
        XCTAssertEqual(result, "Hello World!")
    }

    func testAllFourPRVariablesAreReplaced() {
        let template = "repo={{repo}} pr={{prNumber}} branch={{branch}} sha={{sha}}"
        let vars: [String: String] = [
            "repo": "Ala-com/foo",
            "prNumber": "42",
            "branch": "feature/JWT-1",
            "sha": "deadbeef"
        ]
        let result = PromptInterpolator.interpolate(template, vars: vars)
        XCTAssertEqual(result, "repo=Ala-com/foo pr=42 branch=feature/JWT-1 sha=deadbeef")
    }

    func testMultipleOccurrencesOfSameKeyAreAllReplaced() {
        let template = "{{key}} and {{key}} again"
        let result = PromptInterpolator.interpolate(template, vars: ["key": "X"])
        XCTAssertEqual(result, "X and X again")
    }

    // MARK: - interpolate: whitespace tolerance

    func testWhitespaceInsideBracesIsIgnored() {
        let result = PromptInterpolator.interpolate("{{ name }}", vars: ["name": "Alice"])
        XCTAssertEqual(result, "Alice")
    }

    func testLeadingWhitespaceOnlyInsideBraces() {
        let result = PromptInterpolator.interpolate("{{  repo}}", vars: ["repo": "org/repo"])
        XCTAssertEqual(result, "org/repo")
    }

    func testTrailingWhitespaceOnlyInsideBraces() {
        let result = PromptInterpolator.interpolate("{{sha  }}", vars: ["sha": "abc"])
        XCTAssertEqual(result, "abc")
    }

    // MARK: - interpolate: unknown variables left literal

    func testUnknownVariableIsLeftLiteral() {
        let result = PromptInterpolator.interpolate("value={{typo}}", vars: ["repo": "x"])
        XCTAssertEqual(result, "value={{typo}}")
    }

    func testMixOfKnownAndUnknownVariables() {
        let result = PromptInterpolator.interpolate(
            "{{repo}} {{unknown}}",
            vars: ["repo": "Ala-com/bar"]
        )
        XCTAssertEqual(result, "Ala-com/bar {{unknown}}")
    }

    // MARK: - interpolate: malformed / unbalanced delimiters

    func testUnbalancedOpenBraceLeftLiteral() {
        let result = PromptInterpolator.interpolate("{{ not closed", vars: ["not closed": "x"])
        XCTAssertEqual(result, "{{ not closed")
    }

    func testUnbalancedCloseBraceLeftLiteral() {
        let result = PromptInterpolator.interpolate("no open }}", vars: [:])
        XCTAssertEqual(result, "no open }}")
    }

    func testSingleBraceLeftLiteral() {
        let result = PromptInterpolator.interpolate("{single}", vars: ["single": "x"])
        XCTAssertEqual(result, "{single}")
    }

    // MARK: - interpolate: empty template

    func testEmptyTemplateReturnsEmpty() {
        let result = PromptInterpolator.interpolate("", vars: ["repo": "x"])
        XCTAssertEqual(result, "")
    }

    func testTemplateWithNoTokensIsReturnedAsIs() {
        let template = "No placeholders here."
        let result = PromptInterpolator.interpolate(template, vars: ["repo": "x"])
        XCTAssertEqual(result, template)
    }

    // MARK: - unknownVariables

    func testUnknownVariablesEmptyWhenAllKnown() {
        let template = "{{repo}} {{prNumber}} {{branch}} {{sha}}"
        let result = PromptInterpolator.unknownVariables(
            in: template,
            knownKeys: ReviewPromptStore.knownVariableKeys
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testUnknownVariablesReturnsSingleUnknown() {
        let template = "{{repo}} {{shaa}}"
        let result = PromptInterpolator.unknownVariables(
            in: template,
            knownKeys: ReviewPromptStore.knownVariableKeys
        )
        XCTAssertEqual(result, ["shaa"])
    }

    func testUnknownVariablesIsDeduplicatedAndOrderedByFirstAppearance() {
        let template = "{{foo}} {{bar}} {{foo}} {{baz}} {{bar}}"
        let result = PromptInterpolator.unknownVariables(in: template, knownKeys: [])
        XCTAssertEqual(result, ["foo", "bar", "baz"])
    }

    func testUnknownVariablesExcludesKnownKeys() {
        let template = "{{repo}} {{unknown1}} {{prNumber}} {{unknown2}}"
        let result = PromptInterpolator.unknownVariables(
            in: template,
            knownKeys: ReviewPromptStore.knownVariableKeys
        )
        XCTAssertEqual(result, ["unknown1", "unknown2"])
    }

    func testUnknownVariablesEmptyTemplateReturnsEmpty() {
        let result = PromptInterpolator.unknownVariables(in: "", knownKeys: ["repo"])
        XCTAssertTrue(result.isEmpty)
    }

    func testUnknownVariablesWithWhitespaceInsideBraces() {
        let template = "{{ typo }}"
        let result = PromptInterpolator.unknownVariables(
            in: template,
            knownKeys: ReviewPromptStore.knownVariableKeys
        )
        XCTAssertEqual(result, ["typo"])
    }
}
