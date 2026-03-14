//
//  ReviewVersioningTests.swift
//  WorkHomepageTests
//
//  Slice 14 — Review versioning + history view.
//
//  Two surfaces under test:
//
//   1. `ReviewStore.versions(prKey:)` — newest-first ordering for the
//      modal's History disclosure.
//   2. `ReviewStore.latestForPRAtSha(prKey:headSha:)` — drives the
//      "reuse vs. start fresh" decision in `ReviewsTab.startReview`.
//   3. `ReviewVersioning.shouldStartNewRun(existingForSha:force:)` —
//      pure decision helper, table-driven.
//
//  All store tests run against an in-memory ModelContainer so we never
//  touch disk and the tests are independent.
//

import XCTest
import SwiftData
@testable import WorkHomepage

@MainActor
final class ReviewVersioningTests: XCTestCase {

    // MARK: - Fixture

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Insert a Review with explicit `startedAt` so we control ordering
    /// without sleeping. Findings are intentionally simple (severity +
    /// title) — the versioning logic doesn't read them.
    @discardableResult
    private func insertReview(
        in context: ModelContext,
        prKey: String,
        repo: String,
        prNumber: Int,
        headSha: String,
        startedAt: Date,
        state: String = "completed"
    ) -> Review {
        let review = Review(
            prKey: prKey,
            repoFullName: repo,
            prNumber: prNumber,
            headSha: headSha,
            headBranch: "feature/x",
            state: state,
            startedAt: startedAt
        )
        context.insert(review)
        try? context.save()
        return review
    }

    // MARK: - versions(prKey:)

    func testVersionsReturnsNewestFirst() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date()
        let oldest = insertReview(
            in: context,
            prKey: "org/repo#10",
            repo: "org/repo",
            prNumber: 10,
            headSha: "aaaa1111",
            startedAt: now.addingTimeInterval(-3000)
        )
        let middle = insertReview(
            in: context,
            prKey: "org/repo#10",
            repo: "org/repo",
            prNumber: 10,
            headSha: "bbbb2222",
            startedAt: now.addingTimeInterval(-1500)
        )
        let newest = insertReview(
            in: context,
            prKey: "org/repo#10",
            repo: "org/repo",
            prNumber: 10,
            headSha: "cccc3333",
            startedAt: now
        )
        // Decoy on a different PR — must NOT show up.
        insertReview(
            in: context,
            prKey: "org/other#99",
            repo: "org/other",
            prNumber: 99,
            headSha: "dddd4444",
            startedAt: now
        )

        let store = ReviewStore(context: context)
        let versions = store.versions(prKey: "org/repo#10")

        XCTAssertEqual(versions.count, 3, "Decoy PR must be excluded")
        XCTAssertEqual(versions.map(\.id), [newest.id, middle.id, oldest.id])
        XCTAssertEqual(versions.map(\.headSha), ["cccc3333", "bbbb2222", "aaaa1111"])
    }

    func testVersionsForUnknownPRIsEmpty() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        XCTAssertEqual(store.versions(prKey: "org/missing#1"), [])
    }

    // MARK: - latestForPRAtSha

    func testLatestForPRAtShaReturnsNilForUnknownPair() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        // A row exists for the PR but at a DIFFERENT sha — must miss.
        insertReview(
            in: context,
            prKey: "org/repo#42",
            repo: "org/repo",
            prNumber: 42,
            headSha: "feedface",
            startedAt: Date()
        )

        let store = ReviewStore(context: context)
        XCTAssertNil(
            store.latestForPRAtSha(prKey: "org/repo#42", headSha: "deadbeef"),
            "Unknown sha must miss even when prKey has rows"
        )
        XCTAssertNil(
            store.latestForPRAtSha(prKey: "org/missing#1", headSha: "feedface"),
            "Unknown prKey must miss"
        )
    }

    func testLatestForPRAtShaReturnsMatchingReview() throws {
        let container = try makeContainer()
        let context = ModelContext(container)

        let now = Date()
        // Two rows on the same (prKey, sha) — second one was a forced
        // re-review. We expect the newer-by-startedAt to win.
        insertReview(
            in: context,
            prKey: "org/repo#7",
            repo: "org/repo",
            prNumber: 7,
            headSha: "deadbeef",
            startedAt: now.addingTimeInterval(-600)
        )
        let newer = insertReview(
            in: context,
            prKey: "org/repo#7",
            repo: "org/repo",
            prNumber: 7,
            headSha: "deadbeef",
            startedAt: now
        )
        // A row at a different sha — must NOT win.
        insertReview(
            in: context,
            prKey: "org/repo#7",
            repo: "org/repo",
            prNumber: 7,
            headSha: "cafebabe",
            startedAt: now.addingTimeInterval(60)
        )

        let store = ReviewStore(context: context)
        let hit = store.latestForPRAtSha(prKey: "org/repo#7", headSha: "deadbeef")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.id, newer.id, "Tie-breaker must pick the newest startedAt for the matching pair")
    }

    // MARK: - ReviewVersioning.shouldStartNewRun (table-driven)

    func testShouldStartNewRun_NoExistingReturnsTrue() throws {
        XCTAssertTrue(
            ReviewVersioning.shouldStartNewRun(existingForSha: nil, force: false),
            "No prior row → must start a new run"
        )
        XCTAssertTrue(
            ReviewVersioning.shouldStartNewRun(existingForSha: nil, force: true),
            "force=true with no prior row still starts a new run"
        )
    }

    func testShouldStartNewRun_CompletedNotForcedReusesExisting() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let completed = insertReview(
            in: context,
            prKey: "org/repo#1",
            repo: "org/repo",
            prNumber: 1,
            headSha: "abc",
            startedAt: Date(),
            state: "completed"
        )
        XCTAssertFalse(
            ReviewVersioning.shouldStartNewRun(existingForSha: completed, force: false),
            "completed + force=false → reuse existing row"
        )
    }

    func testShouldStartNewRun_CompletedForcedStartsNew() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let completed = insertReview(
            in: context,
            prKey: "org/repo#1",
            repo: "org/repo",
            prNumber: 1,
            headSha: "abc",
            startedAt: Date(),
            state: "completed"
        )
        XCTAssertTrue(
            ReviewVersioning.shouldStartNewRun(existingForSha: completed, force: true),
            "completed + force=true (Re-review button) → start a fresh run"
        )
    }

    func testShouldStartNewRun_NonCompletedTerminalStatesAlwaysStartNew() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        // failed / timeout / cancelled rows must NOT be reused — those
        // didn't produce a usable verdict.
        for state in ["failed", "timeout", "cancelled"] {
            let row = insertReview(
                in: context,
                prKey: "org/repo#\(state)",
                repo: "org/repo",
                prNumber: 1,
                headSha: "abc",
                startedAt: Date(),
                state: state
            )
            XCTAssertTrue(
                ReviewVersioning.shouldStartNewRun(existingForSha: row, force: false),
                "\(state) row must trigger a fresh run on click (force=false)"
            )
            XCTAssertTrue(
                ReviewVersioning.shouldStartNewRun(existingForSha: row, force: true),
                "\(state) row + force=true also starts fresh"
            )
        }
    }

    func testShouldStartNewRun_NonTerminalStatesStartNew() throws {
        // Defensive: queued/running rows shouldn't normally be passed in
        // (the caller intercepts those upstream), but if one slips through
        // the helper still hands back "start new" rather than reusing.
        let container = try makeContainer()
        let context = ModelContext(container)
        for state in ["queued", "running"] {
            let row = insertReview(
                in: context,
                prKey: "org/repo#\(state)",
                repo: "org/repo",
                prNumber: 1,
                headSha: "abc",
                startedAt: Date(),
                state: state
            )
            XCTAssertTrue(
                ReviewVersioning.shouldStartNewRun(existingForSha: row, force: false),
                "\(state) row must not be treated as reusable"
            )
        }
    }
}
