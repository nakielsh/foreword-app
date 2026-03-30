//
//  PreReviewSummaryStoreTests.swift
//  WorkHomepageTests
//
//  Slice 24 — Pre-Review Summary tracer.
//
//  Verifies `PreReviewSummaryStore` CRUD behaviour against an in-memory
//  `ModelContainer`. Pattern-matched from `ReviewStoreDropTests.swift`.
//
//  Coverage:
//    - `save` + `existing` round-trips byte-equal.
//    - Different `headSha` for the same `prKey` produce two distinct rows.
//    - `existing` returns nil for unknown (prKey, headSha) pairs.
//    - `dropForPR` removes all summaries for that prKey regardless of headSha.
//    - `dropForPR` with an unknown prKey is a no-op.
//

import XCTest
import SwiftData
@testable import WorkHomepage

@MainActor
final class PreReviewSummaryStoreTests: XCTestCase {

    // MARK: - Fixture

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([PreReviewSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeSummary(
        prKey: String = "org/repo#1",
        headSha: String = "abc123",
        what: String = "What text",
        why: String = "Why text",
        risk: String = "Risk text"
    ) -> PreReviewSummary {
        PreReviewSummary(
            prKey: prKey,
            headSha: headSha,
            what: what,
            why: why,
            risk: risk,
            generatedAt: Date()
        )
    }

    // MARK: - save + existing round-trip

    func testSaveAndExistingRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        let summary = makeSummary(prKey: "org/repo#42", headSha: "deadbeef", what: "W", why: "Y", risk: "R")
        store.save(summary)

        let fetched = store.existing(prKey: "org/repo#42", headSha: "deadbeef")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.what, "W")
        XCTAssertEqual(fetched?.why, "Y")
        XCTAssertEqual(fetched?.risk, "R")
        XCTAssertEqual(fetched?.prKey, "org/repo#42")
        XCTAssertEqual(fetched?.headSha, "deadbeef")
    }

    // MARK: - Nil for unknown pair

    func testExistingReturnsNilForUnknownPrKey() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1"))

        XCTAssertNil(store.existing(prKey: "org/repo#999", headSha: "sha1"))
    }

    func testExistingReturnsNilForUnknownHeadSha() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1"))

        XCTAssertNil(store.existing(prKey: "org/repo#1", headSha: "sha999"))
    }

    // MARK: - Different headShas → distinct rows

    func testDifferentHeadShaProducesDistinctRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1", what: "First"))
        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha2", what: "Second"))

        let first = store.existing(prKey: "org/repo#1", headSha: "sha1")
        let second = store.existing(prKey: "org/repo#1", headSha: "sha2")

        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertEqual(first?.what, "First")
        XCTAssertEqual(second?.what, "Second")

        // Ensure they are distinct objects (different composite ids).
        XCTAssertNotEqual(first?.id, second?.id)
    }

    // MARK: - dropForPR

    func testDropForPRRemovesAllShasForThatPRKey() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        // Two SHAs for PR #1, one for PR #2.
        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1a"))
        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1b"))
        store.save(makeSummary(prKey: "org/repo#2", headSha: "sha2a"))

        // Pre-condition.
        XCTAssertNotNil(store.existing(prKey: "org/repo#1", headSha: "sha1a"))
        XCTAssertNotNil(store.existing(prKey: "org/repo#1", headSha: "sha1b"))
        XCTAssertNotNil(store.existing(prKey: "org/repo#2", headSha: "sha2a"))

        store.dropForPR("org/repo#1")

        // Both SHAs for PR #1 must be gone.
        XCTAssertNil(store.existing(prKey: "org/repo#1", headSha: "sha1a"))
        XCTAssertNil(store.existing(prKey: "org/repo#1", headSha: "sha1b"))

        // PR #2 must be untouched.
        XCTAssertNotNil(store.existing(prKey: "org/repo#2", headSha: "sha2a"))
    }

    func testDropForPRWithUnknownKeyIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        store.save(makeSummary(prKey: "org/repo#1", headSha: "sha1"))

        // Should not throw or remove the existing row.
        store.dropForPR("org/repo#999")

        XCTAssertNotNil(store.existing(prKey: "org/repo#1", headSha: "sha1"))
    }

    func testDropForPROnEmptyStoreIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)

        // Must not crash on an empty store.
        store.dropForPR("org/repo#1")

        let descriptor = FetchDescriptor<PreReviewSummary>()
        XCTAssertEqual(try context.fetch(descriptor).count, 0)
    }
}
