//
//  ReviewsModels.swift
//  Foreword
//
//  Slice 02 — Reviews tab full parity.
//
//  Models the Reviews tab needs on top of slice 01's `PullRequest`.
//  Includes:
//    - `PullRequestReviewState` enum mirroring GitHub's REST review `state` field.
//    - `PendingReviewPR` (review-requested:@me with derived approvals/draft/dismissed).
//    - `ReviewedPR` (reviewed-by:@me with my-last-review-state and new-commits-since-review).
//    - REST decode shapes for the `pulls/{n}/reviews` and `pulls/{n}/commits`
//      endpoints (kept private file-scope to the sidecar where they are used,
//      but the parts needed for pure derivation tests are shared here).
//    - `ReviewsDerive` — pure functions for the per-PR derivations the Reviews
//      tab depends on (approval count, my-last-review-state, new-commits,
//      is-dismissed, filter visibility). All logic the tests need lives here so
//      tests don't need a SwiftUI runtime.
//

import struct Foundation.URL
import struct Foundation.Date

// MARK: - Review state enum

/// Maps GitHub's REST review `state` field. Lowercased raw values so persisting
/// or logging stays grep-friendly. `.pending` covers PENDING (in-progress) and
/// `.commented` is the catch-all for unknown states (matching `index.html`'s
/// "anything not APPROVED/CHANGES_REQUESTED treats as commented" behavior).
enum PullRequestReviewState: String, Hashable, Codable {
    case approved
    case changesRequested = "changes_requested"
    case commented
    case dismissed
    case pending

    /// Parse a raw GitHub state string (e.g. `"APPROVED"`, `"CHANGES_REQUESTED"`).
    /// Unknown / nil states default to `.commented`, matching the JS behavior.
    static func parse(_ raw: String?) -> PullRequestReviewState {
        switch raw {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "DISMISSED": return .dismissed
        case "PENDING": return .pending
        case "COMMENTED": return .commented
        default: return .commented
        }
    }
}

// MARK: - Pending review PRs

/// One PR awaiting your review. Backed by the `review-requested:@me` search.
/// `isDismissed` is only true when the user has a prior DISMISSED review on
/// this PR but is still listed as a requested reviewer.
struct PendingReviewPR: Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let authorLogin: String
    let repoFullName: String
    let createdAt: Date
    let isDraft: Bool
    let approvalCount: Int
    let changesRequestedCount: Int
    /// True when the user's prior review on this PR was DISMISSED but they are
    /// still on the requested reviewers list. Mirrors `index.html`'s
    /// `dismissedPRs` collection layered into the visible set when the
    /// "Show my dismissed reviews" toggle is on.
    let isDismissed: Bool
    /// The user's last review state, if they ever reviewed this PR before
    /// being re-requested. Used for the "↻ Approved/Changes/Commented"
    /// re-review tag on the card.
    let myPriorReviewState: PullRequestReviewState?
    /// Head branch ref (e.g. `feature/PROJ-123`). Nil when not available in the
    /// search payload — the GitHub issues search endpoint does not include
    /// `head.ref`, so this is populated only when a separate PR fetch provides it.
    /// `JiraBadgeView` renders `EmptyView` when nil.
    let branchRef: String?
    /// Head commit SHA. Populated by the per-PR branch-info fetch. Used by
    /// `SummarizeView` to look up cached `PreReviewSummary` rows on appear so
    /// the bullet block is restored across relaunches without re-running.
    let headSha: String?
    /// GitHub avatar URL of the PR author. Sourced from `user.avatar_url` in
    /// the `/search/issues` payload. Nil when not available.
    let authorAvatarURL: String?
    /// Per-reviewer status entries fetched via GraphQL (`fetchPRReviewState`).
    /// Populated after the initial search result arrives; defaults to `[]` so
    /// cards render immediately with count-only fallback until the async fetch
    /// completes. Individual fetch failures also leave this empty.
    let reviewerEntries: [ReviewerEntry]
}

// MARK: - Reviewed-by-me PRs

/// One open PR you previously reviewed (and is no longer in the pending set).
/// Drives the three sub-sections on the Reviews tab.
struct ReviewedPR: Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let authorLogin: String
    let repoFullName: String
    let createdAt: Date
    let isDraft: Bool
    let approvalCount: Int
    let changesRequestedCount: Int
    /// Your last effective review state on this PR. The "effective" state
    /// prefers APPROVED/CHANGES_REQUESTED over the trailing COMMENTED entries
    /// (mirrors `index.html`'s `dominated` rule).
    let myLastReviewState: PullRequestReviewState
    /// When you submitted that effective review, used to compute
    /// `newCommitsSinceReview`.
    let myLastReviewSubmittedAt: Date?
    /// Number of commits with `committer.date` (or `author.date`) strictly
    /// after `myLastReviewSubmittedAt`. Zero when no review timestamp is
    /// known (we treat unknown as "no new changes" — index.html parity).
    let newCommitsSinceReview: Int
    /// Head branch ref (e.g. `feature/PROJ-123`). Nil when not available in the
    /// search payload — the GitHub issues search endpoint does not include
    /// `head.ref`. `JiraBadgeView` renders `EmptyView` when nil.
    let branchRef: String?
    /// Head commit SHA. Populated by the per-PR branch-info fetch. Used by
    /// `SummarizeView` to look up cached `PreReviewSummary` rows on appear so
    /// the bullet block is restored across relaunches without re-running.
    let headSha: String?
    /// GitHub avatar URL of the PR author. Sourced from `user.avatar_url` in
    /// the `/search/issues` payload. Nil when not available.
    let authorAvatarURL: String?
    /// Per-reviewer status entries fetched via GraphQL (`fetchPRReviewState`).
    /// Populated after the initial search result arrives; defaults to `[]` so
    /// cards render immediately with count-only fallback until the async fetch
    /// completes. Individual fetch failures also leave this empty.
    let reviewerEntries: [ReviewerEntry]
}

// MARK: - REST decode shapes (shared with tests + sidecar)

/// Minimal decode of a single `/repos/{repo}/pulls/{number}/reviews` entry.
/// Public so unit tests can build fixtures without spinning up URLSession.
struct PRReviewDTO: Decodable, Hashable {
    let user: User?
    let state: String
    let submittedAt: Date?

    struct User: Decodable, Hashable {
        let login: String
        let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case user
        case state
        case submittedAt = "submitted_at"
    }
}

/// Minimal decode of a single `/repos/{repo}/pulls/{number}/commits` entry.
/// Only the committer/author timestamps matter for the
/// "new commits since your review" derivation; everything else is dropped.
struct PRCommitDTO: Decodable, Hashable {
    let commit: Commit

    struct Commit: Decodable, Hashable {
        let committer: GitActor?
        let author: GitActor?
    }

    struct GitActor: Decodable, Hashable {
        let date: Date?
    }

    /// Effective commit timestamp — prefers committer date (matches what the
    /// JS does), falls back to author date.
    var effectiveDate: Date? {
        commit.committer?.date ?? commit.author?.date
    }
}

/// Decode of `/search/issues` payload extended with `draft`/`created_at`/`body`.
/// The Reviews tab needs `draft` for stats and `created_at` for the time-ago
/// label on each card. Decoupled from slice 01's `PullRequest` to leave that
/// model untouched.
struct ReviewsSearchPR: Decodable, Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let user: User
    let repositoryURL: URL
    let draft: Bool?
    let createdAt: Date

    struct User: Decodable, Hashable {
        let login: String
        /// GitHub avatar URL. Present in REST search payloads as `avatar_url`.
        let avatarURL: String?

        enum CodingKeys: String, CodingKey {
            case login
            case avatarURL = "avatar_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case htmlURL = "html_url"
        case user
        case repositoryURL = "repository_url"
        case draft
        case createdAt = "created_at"
    }

    /// "<org>/<repo>" parsed from the tail of `repositoryURL`.
    var repoFullName: String {
        let components = repositoryURL.pathComponents
        guard components.count >= 4 else { return repositoryURL.lastPathComponent }
        let org = components[components.count - 2]
        let repo = components[components.count - 1]
        return "\(org)/\(repo)"
    }
}

// MARK: - Pure derivations

/// Pure (no I/O) functions the Reviews tab depends on. Held in an enum
/// namespace so tests can hit them directly — no SwiftUI, no URLSession.
enum ReviewsDerive {

    /// Approval count: latest review per reviewer that is APPROVED. Matches
    /// the JS rule where DISMISSED overwrites a prior APPROVED entry, so a
    /// dismissed approval no longer counts.
    static func approvalCount(reviews: [PRReviewDTO]) -> Int {
        latestPerReviewerWithDominance(reviews: reviews).values.filter { $0 == .approved }.count
    }

    /// Number of distinct reviewers whose latest non-comment state is
    /// CHANGES_REQUESTED.
    static func changesRequestedCount(reviews: [PRReviewDTO]) -> Int {
        latestPerReviewerWithDominance(reviews: reviews).values.filter { $0 == .changesRequested }.count
    }

    /// "My last effective review state" using the same dominance rule as the JS:
    /// prefer the trailing APPROVED/CHANGES_REQUESTED/DISMISSED entries over
    /// trailing COMMENTED entries. Returns nil if I never reviewed this PR.
    /// Reviews are assumed to be in chronological order (GitHub returns them
    /// that way).
    static func myLastReviewState(reviews: [PRReviewDTO], login: String) -> PullRequestReviewState? {
        let mine = reviews.filter { $0.user?.login == login }
        guard !mine.isEmpty else { return nil }
        let dominated = mine.filter {
            let s = PullRequestReviewState.parse($0.state)
            return s == .approved || s == .changesRequested || s == .dismissed
        }
        let effective = dominated.last ?? mine.last
        return PullRequestReviewState.parse(effective?.state)
    }

    /// Submitted-at of the effective last review, mirroring `myLastReviewState`.
    static func myLastReviewSubmittedAt(reviews: [PRReviewDTO], login: String) -> Date? {
        let mine = reviews.filter { $0.user?.login == login }
        guard !mine.isEmpty else { return nil }
        let dominated = mine.filter {
            let s = PullRequestReviewState.parse($0.state)
            return s == .approved || s == .changesRequested || s == .dismissed
        }
        let effective = dominated.last ?? mine.last
        return effective?.submittedAt
    }

    /// Count of commits whose `effectiveDate` is strictly after the given
    /// review timestamp. Returns 0 when `since` is nil (parity with the JS,
    /// which guards on `myReviewDate`).
    static func newCommitsSinceReview(commits: [PRCommitDTO], since: Date?) -> Int {
        guard let since else { return 0 }
        return commits.filter { c in
            guard let d = c.effectiveDate else { return false }
            return d > since
        }.count
    }

    /// True when my last review was DISMISSED. The Reviews tab uses this to
    /// build the "dismissed" sub-collection that surfaces only when the
    /// "Show my dismissed reviews" toggle is on.
    static func isDismissedByMe(reviews: [PRReviewDTO], login: String) -> Bool {
        myLastReviewState(reviews: reviews, login: login) == .dismissed
    }

    /// Filter rule for the pending grid:
    ///   `hide PR iff approvalCount >= threshold`.
    /// Threshold is clamped to 1...5 by the picker; here we just compare.
    static func isHiddenByApprovalThreshold(approvalCount: Int, threshold: Int) -> Bool {
        approvalCount >= threshold
    }

    // MARK: - Private helpers

    /// "Latest review per reviewer", but DISMISSED, APPROVED, and
    /// CHANGES_REQUESTED entries replace any earlier entry for the same login.
    /// COMMENTED entries are ignored (consistent with how the JS builds its
    /// `map` by only writing entries with state in
    /// {APPROVED, CHANGES_REQUESTED, DISMISSED}).
    /// Returns a `[login: state]` map.
    private static func latestPerReviewerWithDominance(reviews: [PRReviewDTO]) -> [String: PullRequestReviewState] {
        var map: [String: PullRequestReviewState] = [:]
        for r in reviews {
            guard let login = r.user?.login else { continue }
            let s = PullRequestReviewState.parse(r.state)
            if s == .approved || s == .changesRequested || s == .dismissed {
                map[login] = s
            }
        }
        return map
    }
}
