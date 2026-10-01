//
//  ReviewStoreDropTests.swift
//  WorkHomepageTests
//
//  Slice 15 — verify `ReviewStore.dropForPR` and `distinctTrackedPRKeys`.
//
//  The cleanup contract is two-sided:
//    1. `dropForPR(prKey:)` deletes every Review row matching the key, and
//       cascades to its Findings via the `@Relationship(deleteRule: .cascade)`
//       on `Review.findings`. Other PRs' rows are untouched.
//    2. `distinctTrackedPRKeys()` returns the set of unique `prKey`s for
//       which at least one Review row currently exists.
//
//  Both run against an in-memory ModelContainer so we never hit disk.
//

import XCTest
import SwiftData
@testable import WorkHomepage

@MainActor
final class ReviewStoreDropTests: XCTestCase {

    // MARK: - Fixture

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult
    private func insertReview(
        in context: ModelContext,
        prKey: String,
        repo: String,
        prNumber: Int,
        state: String = "completed",
        findingTitles: [String] = []
    ) -> Review {
        let review = Review(
            prKey: prKey,
            repoFullName: repo,
            prNumber: prNumber,
            headSha: "deadbeef",
            headBranch: "feature/x",
            state: state
        )
        context.insert(review)
        for title in findingTitles {
            let finding = Finding(
                severity: "minor",
                file: "Foo.swift",
                line: 1,
                title: title,
                message: "m",
                review: review
            )
            context.insert(finding)
        }
        try? context.save()
        return review
    }

    // MARK: - dropForPR

    func testDropForPRRemovesOnlyMatchingReviewsAndCascadesFindings() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // Two PRs, each with two findings. Plus a second review on PR A so
        // we also exercise the multi-Review-per-PR case.
        insertReview(
            in: context,
            prKey: "acme/widgets#42",
            repo: "acme/widgets",
            prNumber: 42,
            findingTitles: ["A1-finding-1", "A1-finding-2"]
        )
        insertReview(
            in: context,
            prKey: "acme/widgets#42",
            repo: "acme/widgets",
            prNumber: 42,
            findingTitles: ["A2-finding-1"]
        )
        insertReview(
            in: context,
            prKey: "acme/other#7",
            repo: "acme/other",
            prNumber: 7,
            findingTitles: ["B-finding-1", "B-finding-2"]
        )

        // Pre-condition: 3 reviews, 5 findings.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Review>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Finding>()).count, 5)

        let store = ReviewStore(context: context)
        store.dropForPR(prKey: "acme/widgets#42")

        let remainingReviews = try context.fetch(FetchDescriptor<Review>())
        let remainingFindings = try context.fetch(FetchDescriptor<Finding>())

        XCTAssertEqual(remainingReviews.count, 1, "Only PR #7 review should remain")
        XCTAssertEqual(remainingReviews.first?.prKey, "acme/other#7")
        XCTAssertEqual(remainingFindings.count, 2, "Findings on PR #42 should cascade")
        let titles = remainingFindings.map(\.title).sorted()
        XCTAssertEqual(titles, ["B-finding-1", "B-finding-2"])
    }

    func testDropForPRWithUnknownKeyIsNoOp() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        insertReview(
            in: context,
            prKey: "acme/repo#1",
            repo: "acme/repo",
            prNumber: 1,
            findingTitles: ["only"]
        )
        let store = ReviewStore(context: context)
        store.dropForPR(prKey: "acme/missing#999")

        XCTAssertEqual(try context.fetch(FetchDescriptor<Review>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Finding>()).count, 1)
    }

    // MARK: - distinctTrackedPRKeys

    func testDistinctTrackedPRKeysReturnsUniqueSet() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // PR A with two reviews (re-review), PR B with one, PR C with one.
        insertReview(in: context, prKey: "org/a#1", repo: "org/a", prNumber: 1)
        insertReview(in: context, prKey: "org/a#1", repo: "org/a", prNumber: 1)
        insertReview(in: context, prKey: "org/b#2", repo: "org/b", prNumber: 2)
        insertReview(in: context, prKey: "org/c#3", repo: "org/c", prNumber: 3)

        let store = ReviewStore(context: context)
        let keys = Set(store.distinctTrackedPRKeys())
        XCTAssertEqual(keys, ["org/a#1", "org/b#2", "org/c#3"])
    }

    func testDistinctTrackedPRKeysOnEmptyStoreReturnsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        XCTAssertEqual(store.distinctTrackedPRKeys(), [])
    }
}
