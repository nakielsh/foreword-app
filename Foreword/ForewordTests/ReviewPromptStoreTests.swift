//
//  ReviewPromptStoreTests.swift
//  ForewordTests
//
//  Slice 23 — Custom Review Prompt Template.
//
//  Tests for `ReviewPromptStore`. Each test uses a fresh
//  `UserDefaults(suiteName:)` suite to avoid polluting the real user defaults
//  store or interfering with other test runs.
//

import XCTest
@testable import Foreword

final class ReviewPromptStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: ReviewPromptStore!

    override func setUp() {
        super.setUp()
        suiteName = "ReviewPromptStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        store = ReviewPromptStore(defaults: defaults)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    // MARK: - Default behaviour

    func testCurrentReturnsDefaultTemplateWhenKeyAbsent() {
        XCTAssertEqual(store.current(), ReviewPromptStore.defaultTemplate)
    }

    func testDefaultTemplateContainsAllFourPlaceholders() {
        let template = ReviewPromptStore.defaultTemplate
        XCTAssertTrue(template.contains("{{repo}}"),      "default template must contain {{repo}}")
        XCTAssertTrue(template.contains("{{prNumber}}"),  "default template must contain {{prNumber}}")
        XCTAssertTrue(template.contains("{{branch}}"),    "default template must contain {{branch}}")
        XCTAssertTrue(template.contains("{{sha}}"),       "default template must contain {{sha}}")
    }

    func testDefaultTemplateContainsSchemaDirective() {
        XCTAssertTrue(
            ReviewPromptStore.defaultTemplate.contains(OrchestratorPrompt.schemaDirective),
            "default template must include the schema directive so it is not double-appended"
        )
    }

    // MARK: - setCurrent round-trip

    func testSetCurrentAndCurrentRoundTrips() {
        let custom = "My custom template for {{repo}} PR {{prNumber}}."
        store.setCurrent(custom)
        XCTAssertEqual(store.current(), custom)
    }

    func testSetCurrentOverwritesPreviousValue() {
        store.setCurrent("first value")
        store.setCurrent("second value")
        XCTAssertEqual(store.current(), "second value")
    }

    func testSetCurrentEmptyStringResetsToDefault() {
        store.setCurrent("something")
        store.setCurrent("")
        XCTAssertEqual(store.current(), ReviewPromptStore.defaultTemplate)
    }

    func testSetCurrentWhitespaceOnlyResetsToDefault() {
        store.setCurrent("something")
        store.setCurrent("   \n\t  ")
        XCTAssertEqual(store.current(), ReviewPromptStore.defaultTemplate)
    }

    // MARK: - reset

    func testResetRestoresDefaultTemplate() {
        store.setCurrent("custom template")
        store.reset()
        XCTAssertEqual(store.current(), ReviewPromptStore.defaultTemplate)
    }

    func testResetIsIdempotentWhenNoValueSet() {
        store.reset()
        store.reset()
        XCTAssertEqual(store.current(), ReviewPromptStore.defaultTemplate)
    }

    // MARK: - Isolation between store instances

    func testTwoStoresShareTheSameDefaultsKey() {
        let store2 = ReviewPromptStore(defaults: defaults)
        store.setCurrent("shared value")
        XCTAssertEqual(store2.current(), "shared value")
    }

    func testStoresWithDifferentDefaultsAreIsolated() {
        let suite2 = "ReviewPromptStoreTests-\(UUID().uuidString)"
        let defaults2 = UserDefaults(suiteName: suite2)!
        let store2 = ReviewPromptStore(defaults: defaults2)
        defer { UserDefaults().removePersistentDomain(forName: suite2) }

        store.setCurrent("store1 value")
        XCTAssertEqual(store2.current(), ReviewPromptStore.defaultTemplate)
    }

    // testKnownVariableKeysContainsExpectedFour removed — it re-asserted
    // the same constant the production code defines, with no transformation
    // in between. `testDefaultTemplateContainsAllFourPlaceholders` covers
    // the actually-load-bearing claim that the default template references
    // each known key.
}
