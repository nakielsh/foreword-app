//
//  ADFFlattenTests.swift
//  ForewordTests
//
//  Slice 10. Exercises `JiraClient.flattenADF` against handcrafted ADF
//  documents shaped like what Jira returns in `fields.description`. We
//  test the small recursive walker, not the network layer.
//

import XCTest
@testable import Foreword

final class ADFFlattenTests: XCTestCase {

    // MARK: - Single paragraph

    func testSingleParagraph() throws {
        let json = """
        {
          "type": "doc",
          "version": 1,
          "content": [
            { "type": "paragraph", "content": [ { "type": "text", "text": "Hello world" } ] }
          ]
        }
        """
        let result = JiraClient.flattenADF(try parse(json))
        XCTAssertEqual(result, "Hello world")
    }

    // MARK: - Heading + two paragraphs

    func testHeadingPlusTwoParagraphs() throws {
        let json = """
        {
          "type": "doc",
          "version": 1,
          "content": [
            { "type": "heading", "attrs": { "level": 2 },
              "content": [ { "type": "text", "text": "Background" } ] },
            { "type": "paragraph",
              "content": [ { "type": "text", "text": "First paragraph." } ] },
            { "type": "paragraph",
              "content": [ { "type": "text", "text": "Second paragraph." } ] }
          ]
        }
        """
        let result = JiraClient.flattenADF(try parse(json))
        XCTAssertEqual(
            result,
            "Background\n\nFirst paragraph.\n\nSecond paragraph."
        )
    }

    // MARK: - Bullet list

    func testBulletListWithSurroundingText() throws {
        let json = """
        {
          "type": "doc",
          "version": 1,
          "content": [
            { "type": "paragraph",
              "content": [ { "type": "text", "text": "Steps:" } ] },
            { "type": "bulletList",
              "content": [
                { "type": "listItem", "content": [
                    { "type": "paragraph", "content": [ { "type": "text", "text": "First" } ] }
                ]},
                { "type": "listItem", "content": [
                    { "type": "paragraph", "content": [ { "type": "text", "text": "Second" } ] }
                ]},
                { "type": "listItem", "content": [
                    { "type": "paragraph", "content": [ { "type": "text", "text": "Third" } ] }
                ]}
              ]
            },
            { "type": "paragraph",
              "content": [ { "type": "text", "text": "Done." } ] }
          ]
        }
        """
        let result = JiraClient.flattenADF(try parse(json))
        // Each list item flattens to its own paragraph, separated from
        // siblings by `\n\n`. Surrounding paragraphs are also separated.
        XCTAssertEqual(
            result,
            "Steps:\n\nFirst\n\nSecond\n\nThird\n\nDone."
        )
    }

    // MARK: - Empty document

    func testEmptyContentArrayReturnsEmptyString() throws {
        let json = """
        { "type": "doc", "version": 1, "content": [] }
        """
        let result = JiraClient.flattenADF(try parse(json))
        XCTAssertEqual(result, "")
    }

    // MARK: - Nil input

    func testNilDescriptionReturnsEmptyString() {
        let result = JiraClient.flattenADF(nil)
        XCTAssertEqual(result, "")
    }

    // MARK: - Inline marks ignored, only text concatenated

    func testInlineMarksDoNotChangeText() throws {
        let json = """
        {
          "type": "doc",
          "content": [
            { "type": "paragraph", "content": [
                { "type": "text", "text": "bold ", "marks": [ { "type": "strong" } ] },
                { "type": "text", "text": "and italic", "marks": [ { "type": "em" } ] }
            ] }
          ]
        }
        """
        let result = JiraClient.flattenADF(try parse(json))
        XCTAssertEqual(result, "bold and italic")
    }

    // MARK: - hardBreak

    func testHardBreakBecomesSingleNewline() throws {
        let json = """
        {
          "type": "doc",
          "content": [
            { "type": "paragraph", "content": [
                { "type": "text", "text": "line one" },
                { "type": "hardBreak" },
                { "type": "text", "text": "line two" }
            ] }
          ]
        }
        """
        let result = JiraClient.flattenADF(try parse(json))
        XCTAssertEqual(result, "line one\nline two")
    }

    // MARK: - Legacy Wiki Markup string description

    func testWikiMarkupStringPassesThrough() {
        let result = JiraClient.flattenADF("h1. Heading\n\nLegacy stuff.")
        XCTAssertEqual(result, "h1. Heading\n\nLegacy stuff.")
    }

    // MARK: - Helpers

    private func parse(_ s: String) throws -> Any {
        let data = s.data(using: .utf8)!
        return try JSONSerialization.jsonObject(with: data, options: [])
    }
}
