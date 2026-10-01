//
//  ClosedPRDetectorTests.swift
//  ForewordTests
//
//  Slice 15 — verify the closed-PR sweep.
//
//  The detector is plumbed with three injectable seams:
//    - `store` — real ReviewStore over an in-memory SwiftData container.
//    - `evictor` — fake recorder so we never spawn `git`.
//    - `isRunning` — closure that reports whether a given prKey is in
//      `running` state. Default implementation reads the store; tests
//      override it for the "skip running" case so we don't have to fake
//      a Review row in `running` state.
//
//  Cases pinned:
//    1. Tracked PR not in `openPRKeys` → evictor called once + Review rows
//       dropped + cascaded Findings dropped + return value reflects count.
//    2. All tracked PRs are still open → no evictor calls, returns 0.
//    3. Evictor throws → still drops the row, still returns count.
//    4. PR with running review → skipped (no evict, rows survive).
//    5. Malformed prKey → skipped (no evict, no crash).
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class ClosedPRDetectorTests: XCTestCase {

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
        state: String = "completed"
    ) -> Review {
        let review = Review(
            prKey: prKey,
            repoFullName: repo,
            prNumber: prNumber,
            headSha: "abc",
            headBranch: "feature/x",
            state: state
        )
        context.insert(review)
        // One finding so we can also verify the cascade through the detector.
        let finding = Finding(
            severity: "minor",
            file: "F.swift",
            line: 1,
            title: "t",
            message: "m",
            review: review
        )
        context.insert(finding)
        try? context.save()
        return review
    }

    /// Test recorder. Records every (repo, prNumber) call and optionally
    /// throws. We use a class-with-arrays so the closure can mutate it.
    private final class FakeEvictor {
        var calls: [(repo: String, prNumber: Int)] = []
        var throwOn: Set<String> = []

        func evict(repo: String, prNumber: Int) throws {
            calls.append((repo, prNumber))
            if throwOn.contains("\(repo)#\(prNumber)") {
                throw NSError(domain: "FakeEvictor", code: 1)
            }
        }
    }

    // MARK: - 1. Cleanup set = tracked − open

    func testCleansUpClosedPRsAndDropsRows() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertReview(in: context, prKey: "org/repo#1", repo: "org/repo", prNumber: 1)
        insertReview(in: context, prKey: "org/repo#2", repo: "org/repo", prNumber: 2)
        insertReview(in: context, prKey: "org/repo#3", repo: "org/repo", prNumber: 3)

        let store = ReviewStore(context: context)
        let evictor = FakeEvictor()
        let detector = ClosedPRDetector(
            store: store,
            evictor: evictor.evict(repo:prNumber:),
            isRunning: { _ in false }
        )

        let cleaned = detector.cleanupClosedPRs(openPRKeys: ["org/repo#1", "org/repo#2"])

        XCTAssertEqual(cleaned, 1)
        XCTAssertEqual(evictor.calls.count, 1)
        XCTAssertEqual(evictor.calls.first?.repo, "org/repo")
        XCTAssertEqual(evictor.calls.first?.prNumber, 3)

        let remainingKeys = Set(store.distinctTrackedPRKeys())
        XCTAssertEqual(remainingKeys, ["org/repo#1", "org/repo#2"])
        // Cascaded finding for PR #3 is also gone.
        let findings = try context.fetch(FetchDescriptor<Finding>())
        XCTAssertEqual(findings.count, 2)
    }

    // MARK: - 2. All open

    func testAllOpenReturnsZeroAndMakesNoCalls() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertReview(in: context, prKey: "org/repo#1", repo: "org/repo", prNumber: 1)
        insertReview(in: context, prKey: "org/repo#2", repo: "org/repo", prNumber: 2)

        let store = ReviewStore(context: context)
        let evictor = FakeEvictor()
        let detector = ClosedPRDetector(
            store: store,
            evictor: evictor.evict(repo:prNumber:),
            isRunning: { _ in false }
        )

        let cleaned = detector.cleanupClosedPRs(openPRKeys: ["org/repo#1", "org/repo#2"])
        XCTAssertEqual(cleaned, 0)
        XCTAssertTrue(evictor.calls.isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Review>()).count, 2)
    }

    // MARK: - 3. Evictor throws → still drops

    func testEvictorThrowingStillDropsRow() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertReview(in: context, prKey: "org/repo#9", repo: "org/repo", prNumber: 9)

        let store = ReviewStore(context: context)
        let evictor = FakeEvictor()
        evictor.throwOn = ["org/repo#9"]
        let detector = ClosedPRDetector(
            store: store,
            evictor: evictor.evict(repo:prNumber:),
            isRunning: { _ in false }
        )

        let cleaned = detector.cleanupClosedPRs(openPRKeys: [])

        XCTAssertEqual(cleaned, 1)
        XCTAssertEqual(evictor.calls.count, 1)
        XCTAssertTrue(store.distinctTrackedPRKeys().isEmpty)
    }

    // MARK: - 4. Running review skipped

    func testRunningReviewIsSkipped() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertReview(in: context, prKey: "org/repo#5", repo: "org/repo", prNumber: 5, state: "running")
        insertReview(in: context, prKey: "org/repo#6", repo: "org/repo", prNumber: 6)

        let store = ReviewStore(context: context)
        let evictor = FakeEvictor()
        // Stub: PR #5 is "running"; PR #6 is not.
        let detector = ClosedPRDetector(
            store: store,
            evictor: evictor.evict(repo:prNumber:),
            isRunning: { key in key == "org/repo#5" }
        )

        let cleaned = detector.cleanupClosedPRs(openPRKeys: [])

        XCTAssertEqual(cleaned, 1, "Only PR #6 should be cleaned; PR #5 is running")
        XCTAssertEqual(evictor.calls.count, 1)
        XCTAssertEqual(evictor.calls.first?.prNumber, 6)
        // Running PR's row is preserved.
        XCTAssertEqual(store.distinctTrackedPRKeys(), ["org/repo#5"])
    }

    // MARK: - 5. Malformed prKey skipped

    func testMalformedPRKeyIsSkipped() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        insertReview(in: context, prKey: "no-hash-here", repo: "repo", prNumber: 1)
        insertReview(in: context, prKey: "org/repo#7", repo: "org/repo", prNumber: 7)

        let store = ReviewStore(context: context)
        let evictor = FakeEvictor()
        let detector = ClosedPRDetector(
            store: store,
            evictor: evictor.evict(repo:prNumber:),
            isRunning: { _ in false }
        )

        let cleaned = detector.cleanupClosedPRs(openPRKeys: [])

        // Malformed key is skipped (no parse → no evict, no drop) so we only
        // clean PR #7. The malformed row stays — better than crashing.
        XCTAssertEqual(cleaned, 1)
        XCTAssertEqual(evictor.calls.count, 1)
        XCTAssertEqual(evictor.calls.first?.repo, "org/repo")
        XCTAssertEqual(evictor.calls.first?.prNumber, 7)
        XCTAssertEqual(store.distinctTrackedPRKeys(), ["no-hash-here"])
    }

    // MARK: - parsePRKey unit-level coverage

    func testParsePRKeyAcceptsWellFormed() {
        let parsed = ClosedPRDetector.parsePRKey("acme/widgets#123")
        XCTAssertEqual(parsed?.repo, "acme/widgets")
        XCTAssertEqual(parsed?.prNumber, 123)
    }

    func testParsePRKeyRejectsBadInputs() {
        XCTAssertNil(ClosedPRDetector.parsePRKey(""))
        XCTAssertNil(ClosedPRDetector.parsePRKey("nohash"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("only/repo"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("org/repo#"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("#42"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("org#42"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("/repo#42"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("org/#42"))
        XCTAssertNil(ClosedPRDetector.parsePRKey("org/repo#abc"))
    }
}
