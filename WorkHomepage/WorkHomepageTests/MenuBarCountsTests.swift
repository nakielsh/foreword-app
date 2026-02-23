//
//  MenuBarCountsTests.swift
//  WorkHomepageTests
//
//  Slice 16 — covers the menu-bar count seam.
//
//  We don't mock anything: `MenuBarCounts` is a small `@Observable` value
//  bag. The interesting behaviors are
//
//   1. Direct setters (`setAwaiting`, `bumpInFlight`, `dropInFlight`)
//      mutate the published properties.
//   2. `Notification.Name.reviewsAwaitingCountChanged` updates
//      `awaitingReviews` after a brief main-actor hop.
//   3. The hop runs on the main actor — observers receive it on `.main`,
//      and the closure dispatches a `Task { @MainActor in ... }`. Tests
//      `await` a short main-actor yield to let that landing happen before
//      asserting.
//
//  Each test instantiates a fresh `MenuBarCounts` (the singleton is
//  `static let shared`, but the init is internal so tests can side-step the
//  shared instance and avoid leaking state between tests).
//

import XCTest
@testable import WorkHomepage

@MainActor
final class MenuBarCountsTests: XCTestCase {

    // MARK: - Direct setters

    func testSetAwaitingUpdatesProperty() {
        let counts = MenuBarCounts()
        XCTAssertEqual(counts.awaitingReviews, 0)

        counts.setAwaiting(7)
        XCTAssertEqual(counts.awaitingReviews, 7)

        counts.setAwaiting(0)
        XCTAssertEqual(counts.awaitingReviews, 0)
    }

    func testSetAwaitingClampsNegativeToZero() {
        let counts = MenuBarCounts()
        counts.setAwaiting(-3)
        XCTAssertEqual(counts.awaitingReviews, 0)
    }

    func testBumpInFlightIncrements() {
        let counts = MenuBarCounts()
        let start = counts.inFlightReviews

        counts.bumpInFlight()
        XCTAssertEqual(counts.inFlightReviews, start + 1)

        counts.bumpInFlight()
        XCTAssertEqual(counts.inFlightReviews, start + 2)
    }

    func testDropInFlightDecrementsButNeverGoesNegative() {
        let counts = MenuBarCounts()
        // Start fresh: drive to a known baseline.
        while counts.inFlightReviews > 0 {
            counts.dropInFlight()
        }
        XCTAssertEqual(counts.inFlightReviews, 0)

        counts.bumpInFlight()
        counts.bumpInFlight()
        XCTAssertEqual(counts.inFlightReviews, 2)

        counts.dropInFlight()
        XCTAssertEqual(counts.inFlightReviews, 1)

        counts.dropInFlight()
        XCTAssertEqual(counts.inFlightReviews, 0)

        // Extra drop must NOT go below zero.
        counts.dropInFlight()
        XCTAssertEqual(counts.inFlightReviews, 0)
    }

    // MARK: - NotificationCenter seam

    func testNotificationUpdatesAwaitingCount() async {
        let counts = MenuBarCounts()
        XCTAssertEqual(counts.awaitingReviews, 0)

        NotificationCenter.default.post(
            name: .reviewsAwaitingCountChanged,
            object: nil,
            userInfo: ["count": 12]
        )

        // The observer is registered with `queue: .main` and dispatches a
        // `Task { @MainActor in ... }`. Yield twice to let both hops land.
        await yieldMainActor()
        await yieldMainActor()

        XCTAssertEqual(counts.awaitingReviews, 12)
    }

    func testNotificationWithoutCountKeyResetsToZero() async {
        let counts = MenuBarCounts()
        counts.setAwaiting(5)
        XCTAssertEqual(counts.awaitingReviews, 5)

        // No userInfo — should fall back to 0.
        NotificationCenter.default.post(name: .reviewsAwaitingCountChanged, object: nil)

        await yieldMainActor()
        await yieldMainActor()

        XCTAssertEqual(counts.awaitingReviews, 0)
    }

    func testNotificationWithNegativeCountClampsToZero() async {
        let counts = MenuBarCounts()
        counts.setAwaiting(4)

        NotificationCenter.default.post(
            name: .reviewsAwaitingCountChanged,
            object: nil,
            userInfo: ["count": -10]
        )

        await yieldMainActor()
        await yieldMainActor()

        XCTAssertEqual(counts.awaitingReviews, 0)
    }

    // MARK: - Refresh-Reviews notification name exists

    func testRefreshReviewsRequestedNotificationNameIsStable() {
        // Sanity check: the constant exists with the expected raw value, so
        // the future receiver knows what string to listen on.
        XCTAssertEqual(
            Notification.Name.refreshReviewsRequested.rawValue,
            "refreshReviewsRequested"
        )
    }

    // MARK: - Helpers

    /// Yields control to the main actor so queued main-actor `Task`s and
    /// `@MainActor` continuations run before the next assertion.
    private func yieldMainActor() async {
        await Task.yield()
    }
}
