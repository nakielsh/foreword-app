//
//  ReviewsParityTests.swift
//  WorkHomepageTests
//
//  Slice 02 — pure derivation tests for the Reviews tab.
//
//  Covers `ReviewsDerive` directly. No SwiftUI, no URLSession, no Keychain.
//  Each test builds plain `PRReviewDTO` / `PRCommitDTO` fixtures and checks
//  one rule: approval count, my-last-review-state, new-commits-since-review,
//  is-dismissed-by-me, and the threshold filter rule.
//

import XCTest
@testable import WorkHomepage

final class ReviewsParityTests: XCTestCase {

    // MARK: - approvalCount

    func testApprovalCountCountsOnlyLatestApprovedPerReviewer() {
        // Two distinct approvers + one comment + one dismissed approver.
        // alice: COMMENTED then APPROVED -> approved.
        // bob: APPROVED -> approved.
        // carol: APPROVED then DISMISSED -> dismissed (does not count).
        // dave: COMMENTED -> commented (ignored from approval map).
        let reviews: [PRReviewDTO] = [
            review(login: "alice", state: "COMMENTED"),
            review(login: "alice", state: "APPROVED"),
            review(login: "bob", state: "APPROVED"),
            review(login: "carol", state: "APPROVED"),
            review(login: "carol", state: "DISMISSED"),
            review(login: "dave", state: "COMMENTED"),
        ]
        XCTAssertEqual(ReviewsDerive.approvalCount(reviews: reviews), 2)
    }

    func testApprovalCountZeroOnEmpty() {
        XCTAssertEqual(ReviewsDerive.approvalCount(reviews: []), 0)
    }

    func testApprovalCountIgnoresPendingAndCommentedOnlyEntries() {
        // Pending should never count, even if it would somehow be the latest
        // entry. The dominance rule only writes APPROVED/CHANGES_REQUESTED/
        // DISMISSED, so a trailing PENDING never wins.
        let reviews: [PRReviewDTO] = [
            review(login: "alice", state: "APPROVED"),
            review(login: "alice", state: "PENDING"),
            review(login: "bob", state: "COMMENTED"),
        ]
        XCTAssertEqual(ReviewsDerive.approvalCount(reviews: reviews), 1)
    }

    func testChangesRequestedCountUsesLatestPerReviewer() {
        let reviews: [PRReviewDTO] = [
            review(login: "alice", state: "CHANGES_REQUESTED"),
            review(login: "alice", state: "APPROVED"),
            review(login: "bob", state: "CHANGES_REQUESTED"),
        ]
        // alice flipped to approved -> only bob remains in changes-requested.
        XCTAssertEqual(ReviewsDerive.changesRequestedCount(reviews: reviews), 1)
    }

    // MARK: - myLastReviewState

    func testMyLastReviewStatePrefersDominatedTrailingEntry() {
        // The JS rule: trailing COMMENTED entries are ignored in favor of
        // the last APPROVED/CHANGES_REQUESTED/DISMISSED entry.
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "APPROVED"),
            review(login: "viewer", state: "COMMENTED"),
            review(login: "viewer", state: "COMMENTED"),
        ]
        XCTAssertEqual(
            ReviewsDerive.myLastReviewState(reviews: reviews, login: "viewer"),
            .approved
        )
    }

    func testMyLastReviewStateFallsBackToTrailingCommentedWhenNoDominated() {
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "COMMENTED"),
            review(login: "viewer", state: "COMMENTED"),
        ]
        XCTAssertEqual(
            ReviewsDerive.myLastReviewState(reviews: reviews, login: "viewer"),
            .commented
        )
    }

    func testMyLastReviewStatePicksLatestDominated() {
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "APPROVED"),
            review(login: "viewer", state: "CHANGES_REQUESTED"),
        ]
        XCTAssertEqual(
            ReviewsDerive.myLastReviewState(reviews: reviews, login: "viewer"),
            .changesRequested
        )
    }

    func testMyLastReviewStateNilWhenNeverReviewed() {
        let reviews: [PRReviewDTO] = [
            review(login: "alice", state: "APPROVED"),
        ]
        XCTAssertNil(ReviewsDerive.myLastReviewState(reviews: reviews, login: "viewer"))
    }

    func testMyLastReviewSubmittedAtFollowsEffectivePick() {
        let approvedAt = Date(timeIntervalSince1970: 1_000)
        let commentedAt = Date(timeIntervalSince1970: 2_000)
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "APPROVED", at: approvedAt),
            review(login: "viewer", state: "COMMENTED", at: commentedAt),
        ]
        XCTAssertEqual(
            ReviewsDerive.myLastReviewSubmittedAt(reviews: reviews, login: "viewer"),
            approvedAt
        )
    }

    // MARK: - newCommitsSinceReview

    func testNewCommitsSinceReviewCountsOnlyAfterTimestamp() {
        let myReview = Date(timeIntervalSince1970: 1_000)
        let commits: [PRCommitDTO] = [
            commit(at: 500),   // before
            commit(at: 1_000), // exact match — strictly-greater rule excludes
            commit(at: 1_500), // after
            commit(at: 2_000), // after
        ]
        XCTAssertEqual(
            ReviewsDerive.newCommitsSinceReview(commits: commits, since: myReview),
            2
        )
    }

    func testNewCommitsZeroWhenNoReviewTimestamp() {
        let commits: [PRCommitDTO] = [
            commit(at: 1_000),
            commit(at: 2_000),
        ]
        XCTAssertEqual(
            ReviewsDerive.newCommitsSinceReview(commits: commits, since: nil),
            0
        )
    }

    func testNewCommitsPrefersCommitterDateThenAuthorDate() {
        // committer.date present -> wins. committer absent -> author wins.
        let myReview = Date(timeIntervalSince1970: 1_000)
        let commits: [PRCommitDTO] = [
            PRCommitDTO(commit: .init(
                committer: .init(date: Date(timeIntervalSince1970: 2_000)),
                author: .init(date: Date(timeIntervalSince1970: 500))
            )),
            PRCommitDTO(commit: .init(
                committer: nil,
                author: .init(date: Date(timeIntervalSince1970: 1_500))
            )),
        ]
        XCTAssertEqual(
            ReviewsDerive.newCommitsSinceReview(commits: commits, since: myReview),
            2
        )
    }

    // MARK: - isDismissedByMe

    func testIsDismissedByMeTrueWhenLatestEffectiveIsDismissed() {
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "APPROVED"),
            review(login: "viewer", state: "DISMISSED"),
        ]
        XCTAssertTrue(ReviewsDerive.isDismissedByMe(reviews: reviews, login: "viewer"))
    }

    func testIsDismissedByMeFalseWhenLatestEffectiveIsApproved() {
        let reviews: [PRReviewDTO] = [
            review(login: "viewer", state: "DISMISSED"),
            review(login: "viewer", state: "APPROVED"),
        ]
        XCTAssertFalse(ReviewsDerive.isDismissedByMe(reviews: reviews, login: "viewer"))
    }

    func testIsDismissedByMeFalseWhenIDidNotReview() {
        let reviews: [PRReviewDTO] = [
            review(login: "alice", state: "DISMISSED"),
        ]
        XCTAssertFalse(ReviewsDerive.isDismissedByMe(reviews: reviews, login: "viewer"))
    }

    // MARK: - threshold filter

    func testIsHiddenAtOrAboveThreshold() {
        XCTAssertTrue(ReviewsDerive.isHiddenByApprovalThreshold(approvalCount: 2, threshold: 2))
        XCTAssertTrue(ReviewsDerive.isHiddenByApprovalThreshold(approvalCount: 5, threshold: 2))
    }

    func testNotHiddenBelowThreshold() {
        XCTAssertFalse(ReviewsDerive.isHiddenByApprovalThreshold(approvalCount: 1, threshold: 2))
        XCTAssertFalse(ReviewsDerive.isHiddenByApprovalThreshold(approvalCount: 0, threshold: 2))
    }

    // MARK: - parse fallback

    func testParseUnknownReviewStateFallsBackToCommented() {
        XCTAssertEqual(PullRequestReviewState.parse("WAT"), .commented)
        XCTAssertEqual(PullRequestReviewState.parse(nil), .commented)
        XCTAssertEqual(PullRequestReviewState.parse("APPROVED"), .approved)
        XCTAssertEqual(PullRequestReviewState.parse("CHANGES_REQUESTED"), .changesRequested)
        XCTAssertEqual(PullRequestReviewState.parse("DISMISSED"), .dismissed)
        XCTAssertEqual(PullRequestReviewState.parse("PENDING"), .pending)
    }

    // MARK: - Helpers

    private func review(
        login: String,
        state: String,
        at: Date? = nil
    ) -> PRReviewDTO {
        PRReviewDTO(
            user: PRReviewDTO.User(login: login, avatarURL: nil),
            state: state,
            submittedAt: at
        )
    }

    private func commit(at epoch: TimeInterval) -> PRCommitDTO {
        PRCommitDTO(commit: .init(
            committer: .init(date: Date(timeIntervalSince1970: epoch)),
            author: nil
        ))
    }
}
