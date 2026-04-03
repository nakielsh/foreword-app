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
    /// Head branch ref (e.g. `feature/JWT-123`). Not present in the GitHub
    /// issues search payload (`/search/issues`), so always nil when decoded
    /// from there. `JiraBadgeView` renders `EmptyView` when nil.
    let branchRef: String?

    struct User: Codable, Hashable {
        let login: String
        /// GitHub avatar URL. Present in REST search payloads as `avatar_url`.
        /// Nil when the field is absent (e.g. fixtures that predate slice 22).
        let avatarURL: URL?

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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title)
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        user = try c.decode(User.self, forKey: .user)
        repositoryURL = try c.decode(URL.self, forKey: .repositoryURL)
        draft = try c.decode(Bool.self, forKey: .draft)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        branchRef = nil
    }

    init(
        id: Int,
        number: Int,
        title: String,
        htmlURL: URL,
        user: User,
        repositoryURL: URL,
        draft: Bool,
        createdAt: Date,
        branchRef: String? = nil
    ) {
        self.id = id
        self.number = number
        self.title = title
        self.htmlURL = htmlURL
        self.user = user
        self.repositoryURL = repositoryURL
        self.draft = draft
        self.createdAt = createdAt
        self.branchRef = branchRef
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
    /// GitHub avatar URL for this reviewer. Nil when not returned by the
    /// GraphQL query (e.g. Team reviewers or pre-slice-22 fixtures).
    let avatarURL: URL?

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
    /// Head branch ref decoded from the GraphQL `headRefName` field
    /// (e.g. `feature/JWT-123`). Nil when not returned by the query.
    /// Piped into `AuthoredPR.branchRef` after assembly so `JiraBadgeView`
    /// can render on My PRs cards without a separate REST round-trip.
    let branchRef: String?

    static let empty = PRReviewState(
        reviewers: [],
        unresolved: .zero,
        totalThreads: 0,
        totalComments: 0,
        branchRef: nil
    )
}
