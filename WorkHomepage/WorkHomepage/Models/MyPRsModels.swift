//
//  MyPRsModels.swift
//  WorkHomepage
//
//  Slice 03 — My PRs tab parity.
//  Decoupled from `PullRequest` (slice 01) to keep that model untouched and to
//  carry the extra fields My PRs needs (`draft`, `created_at`).
//

import struct Foundation.URL
import struct Foundation.Date

/// One open PR authored by the current user, decoded from the REST search payload
/// (`/search/issues?q=author:@me+is:pr+is:open`).
struct AuthoredPR: Codable, Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let user: User
    let repositoryURL: URL
    let draft: Bool
    let createdAt: Date

    struct User: Codable, Hashable {
        let login: String
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
    /// GitHub returns `repository_url` like `https://api.github.com/repos/Ala-com/foo`.
    var repoFullName: String {
        let components = repositoryURL.pathComponents
        guard components.count >= 4 else { return repositoryURL.lastPathComponent }
        let org = components[components.count - 2]
        let repo = components[components.count - 1]
        return "\(org)/\(repo)"
    }
}

/// Latest review state per reviewer, mirroring the five-state model in `index.html`.
enum ReviewerStatus: String, Hashable {
    case approved
    case changesRequested
    case commented
    case dismissed
    case pending
    case reRequested

    var label: String {
        switch self {
        case .approved: return "Approved"
        case .changesRequested: return "Changes"
        case .commented: return "Commented"
        case .dismissed: return "Dismissed"
        case .pending: return "Pending"
        case .reRequested: return "Re-review"
        }
    }
}

struct ReviewerEntry: Hashable, Identifiable {
    let login: String
    let status: ReviewerStatus
    /// True if a re-review was requested *after* the reviewer left a review.
    /// This is independent from `status` so the UI can stack a "↻" mark on top
    /// of the underlying status (matching `index.html`).
    let reRequested: Bool

    var id: String { login }
}

/// Split of unresolved review threads into "awaiting you" (last commenter is
/// somebody else, ball in your court) vs "awaiting others" (you replied last).
struct UnresolvedThreads: Hashable {
    let awaitingYou: Int
    let awaitingOthers: Int

    static let zero = UnresolvedThreads(awaitingYou: 0, awaitingOthers: 0)

    var total: Int { awaitingYou + awaitingOthers }
}

/// Aggregated review state for a single PR, populated from one GraphQL call.
struct PRReviewState: Hashable {
    let reviewers: [ReviewerEntry]
    let unresolved: UnresolvedThreads
    let totalThreads: Int
    let totalComments: Int

    static let empty = PRReviewState(
        reviewers: [],
        unresolved: .zero,
        totalThreads: 0,
        totalComments: 0
    )
}
