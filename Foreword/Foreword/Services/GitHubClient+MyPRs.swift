//
//  GitHubClient+MyPRs.swift
//  Foreword
//
//  Slice 03 — My PRs tab parity.
//
//  Adds three things without touching the existing GitHubClient.swift file:
//  - `GitHubClient.fetchAuthoredPRs()` (REST search)
//  - `GitHubClient.fetchPRReviewState(repo:number:currentUser:)` (single GraphQL call
//    covering requested reviewers, latest review per author, and review threads)
//  - A private `MyPRsAPI` struct (co-located here) that owns the URLSession/auth
//    plumbing. The `GitHubClient` extension methods delegate to it. `MyPRsAPI`
//    is what tests instantiate with a stubbed URLSession because the slice 01
//    `GitHubClient` keeps its session/tokenProvider as `private` stored
//    properties that an extension in a different file can't reach.
//
//  The "awaiting you" vs "awaiting others" derivation is a pure static function
//  on `MyPRsAPI` so tests can hit it directly without URLSession.
//
//  All HTTP plumbing lives in `HTTPClient.swift`.
//

import struct Foundation.URL
import struct Foundation.URLRequest
import class Foundation.URLSession
import class Foundation.HTTPURLResponse
import class Foundation.URLResponse
import class Foundation.JSONDecoder
import class Foundation.JSONSerialization
import struct Foundation.Data
import func Foundation.NSLog

// MARK: - Public surface on GitHubClient

extension GitHubClient {
    /// Fetches the authenticated user's login (`/user`).
    func fetchCurrentUserLogin() async throws -> String {
        try await MyPRsAPI.default().fetchCurrentUserLogin()
    }

    /// Fetches open PRs authored by the authenticated user.
    /// Mirrors `index.html` query: `author:@me+is:pr+is:open`.
    func fetchAuthoredPRs() async throws -> [AuthoredPR] {
        try await MyPRsAPI.default().fetchAuthoredPRs()
    }

    /// Fetches per-reviewer status, review threads, and total comment count for a
    /// single PR. `repo` is `<org>/<name>`, `currentUser` is the login of the
    /// authenticated user (drives "awaiting you" vs "awaiting others").
    func fetchPRReviewState(
        repo: String,
        number: Int,
        currentUser: String
    ) async throws -> PRReviewState {
        try await MyPRsAPI.default().fetchPRReviewState(
            repo: repo,
            number: number,
            currentUser: currentUser
        )
    }
}

// MARK: - Sidecar struct that owns plumbing

/// Independent API surface for the My PRs tab. Mirrors `GitHubClient`'s
/// auth/error semantics but holds its own session/tokenProvider/onUnauthorized
/// so it can be unit-tested with a stubbed `URLSession` (the slice 01 client's
/// equivalents are `private`).
struct MyPRsAPI {
    private let session: URLSession
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void

    init(
        session: URLSession = .shared,
        tokenProvider: @escaping () -> String? = { KeychainStore.get(key: "github.token") },
        onUnauthorized: @escaping () -> Void = { KeychainStore.delete(key: "github.token") }
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
    }

    /// Production defaults: shared session + keychain-backed token + 401-clears-keychain.
    static func `default`() -> MyPRsAPI { MyPRsAPI() }

    private var http: HTTPClient {
        HTTPClient(
            session: session,
            tokenProvider: tokenProvider,
            onUnauthorized: onUnauthorized
        )
    }

    // MARK: - Current user (REST)

    /// Fetches the authenticated user's login from `/user`. The login is
    /// required as input to `fetchPRReviewState` to derive "awaiting you" vs
    /// "awaiting others".
    func fetchCurrentUserLogin() async throws -> String {
        let resp = try await http.getDecoded(
            CurrentUserResponse.self,
            urlString: "https://api.github.com/user"
        )
        return resp.login
    }

    // MARK: - Authored PRs (REST)

    func fetchAuthoredPRs() async throws -> [AuthoredPR] {
        let urlString = "https://api.github.com/search/issues?q=author:@me+is:pr+is:open&sort=updated&order=desc&per_page=100"
        let resp = try await http.getDecoded(AuthoredSearchResponse.self, urlString: urlString)
        return resp.items
    }

    // MARK: - Review state (GraphQL)

    func fetchPRReviewState(
        repo: String,
        number: Int,
        currentUser: String
    ) async throws -> PRReviewState {
        let parts = repo.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else {
            throw GitHubError.transport("Invalid repo \(repo); expected <org>/<name>")
        }
        let owner = String(parts[0])
        let name = String(parts[1])

        let query = """
        query($owner:String!,$name:String!,$number:Int!) {
          repository(owner:$owner,name:$name) {
            pullRequest(number:$number) {
              headRefName
              reviewRequests(first:20) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login avatarUrl }
                    ... on Team { name }
                  }
                }
              }
              latestReviews(first:50) {
                nodes {
                  state
                  author {
                    login
                    ... on User { avatarUrl }
                  }
                }
              }
              reviewThreads(first:100) {
                totalCount
                nodes {
                  isResolved
                  comments(last:1) {
                    totalCount
                    nodes { author { login } }
                  }
                }
              }
            }
          }
        }
        """
        let variables: [String: Any] = ["owner": owner, "name": name, "number": number]

        let response: GraphQLResponse<PRReviewStateRoot> = try await ghGraphQL(
            query: query,
            variables: variables
        )

        // GraphQL 200-with-errors handling. Three cases:
        //  1. errors empty + data present     → happy path.
        //  2. errors non-empty + data present → log + return data; partial
        //     responses (e.g. one missing field on a sub-type) shouldn't
        //     blank the whole tab.
        //  3. errors non-empty + data nil     → throw `.graphqlPartial`.
        //  4. errors empty + data nil         → unreachable per spec; we
        //     treat as `.graphqlPartial([])` rather than a generic decode
        //     error so callers can distinguish it from a malformed body.
        let errors = response.errors ?? []
        let messages = errors.map(\.message)

        if let pr = response.data?.repository?.pullRequest {
            if !errors.isEmpty {
                NSLog("[MyPRsAPI] GraphQL returned partial data with errors: \(messages)")
            }
            return Self.makePRReviewState(payload: pr, currentUser: currentUser)
        }

        // No `pullRequest`. Inspect the errors and the `repository` slot to
        // pick the most specific typed error.
        if response.data?.repository == nil, !errors.isEmpty {
            // `data.repository = null` on GitHub's GraphQL is the
            // canonical shape for "you can't see this repo" — forbidden
            // (private repo without scope) or notFound (deleted / typo).
            // We can't always tell which, but the error messages usually
            // contain `NOT_FOUND` / `FORBIDDEN`.
            let lower = messages.joined(separator: " ").lowercased()
            if lower.contains("not_found") || lower.contains("could not resolve") {
                throw GitHubError.notFound(body: messages.joined(separator: "; "))
            }
            if lower.contains("forbidden") || lower.contains("permission") {
                throw GitHubError.forbidden(body: messages.joined(separator: "; "))
            }
        }
        if !errors.isEmpty {
            throw GitHubError.graphqlPartial(errors: messages)
        }
        throw GitHubError.graphqlPartial(errors: ["Missing pullRequest in GraphQL payload"])
    }

    /// Pure assembly: turns a decoded GraphQL payload + the viewer login into a
    /// `PRReviewState`. Static so tests can hit it without URLSession.
    static func makePRReviewState(
        payload: PRReviewStatePayload,
        currentUser: String
    ) -> PRReviewState {
        var byLogin: [String: ReviewerEntryBuilder] = [:]
        var order: [String] = []

        for node in payload.latestReviews?.nodes ?? [] {
            guard let login = node.author?.login else { continue }
            let status = mapReviewState(node.state)
            let avatarURL = node.author?.avatarUrl.flatMap { URL(string: $0) }
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = ReviewerEntryBuilder(
                login: login,
                status: status,
                reRequested: false,
                avatarURL: avatarURL
            )
        }

        for node in payload.reviewRequests?.nodes ?? [] {
            guard let reviewer = node.requestedReviewer else { continue }
            let login: String?
            let avatarURL: URL?
            switch reviewer {
            case .user(let login_, let url):
                login = login_
                avatarURL = url.flatMap { URL(string: $0) }
            case .team(let name):
                login = name
                avatarURL = nil
            case .unknown:
                login = nil
                avatarURL = nil
            }
            guard let login, !login.isEmpty else { continue }
            if var existing = byLogin[login] {
                existing.reRequested = true
                // Prefer the avatar from reviewRequests if latestReviews didn't carry one.
                if existing.avatarURL == nil, let url = avatarURL {
                    existing.avatarURL = url
                }
                byLogin[login] = existing
            } else {
                order.append(login)
                byLogin[login] = ReviewerEntryBuilder(
                    login: login,
                    status: .pending,
                    reRequested: false,
                    avatarURL: avatarURL
                )
            }
        }

        let entries = order.compactMap { login -> ReviewerEntry? in
            guard let b = byLogin[login] else { return nil }
            return ReviewerEntry(
                login: b.login,
                status: b.status,
                reRequested: b.reRequested,
                avatarURL: b.avatarURL
            )
        }

        let threads = payload.reviewThreads?.nodes ?? []
        let totalThreads = payload.reviewThreads?.totalCount ?? threads.count
        let unresolved = threads.filter { !$0.isResolved }
        let withMyReply = unresolved.filter { thread in
            guard let last = thread.comments?.nodes.last else { return false }
            return last.author?.login == currentUser
        }.count
        let awaitingMe = unresolved.count - withMyReply
        let totalComments = threads.reduce(0) { $0 + ($1.comments?.totalCount ?? 0) }

        return PRReviewState(
            reviewers: entries,
            unresolved: UnresolvedThreads(awaitingYou: awaitingMe, awaitingOthers: withMyReply),
            totalThreads: totalThreads,
            totalComments: totalComments,
            branchRef: payload.headRefName
        )
    }

    // MARK: - GraphQL helper (private)

    /// POSTs a GraphQL query/variables pair and decodes a `GraphQLResponse<T>`.
    /// Mirrors REST auth + 401 path so callers see the same `GitHubError` cases.
    private func ghGraphQL<T: Decodable>(
        query: String,
        variables: [String: Any]
    ) async throws -> GraphQLResponse<T> {
        let body: [String: Any] = ["query": query, "variables": variables]
        let bodyData: Data
        do {
            bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw GitHubError.transport("Failed to encode GraphQL body: \(error.localizedDescription)")
        }

        return try await http.postDecoded(
            GraphQLResponse<T>.self,
            urlString: "https://api.github.com/graphql",
            body: bodyData
        )
    }
}

// MARK: - REST decode shape

private struct AuthoredSearchResponse: Decodable {
    let items: [AuthoredPR]
}

private struct CurrentUserResponse: Decodable {
    let login: String
}

// MARK: - GraphQL decode shapes

/// Top-level GraphQL envelope. Generic for reuse across queries.
struct GraphQLResponse<T: Decodable>: Decodable {
    struct GQLError: Decodable { let message: String }
    let data: T?
    let errors: [GQLError]?
}

struct PRReviewStateRoot: Decodable {
    let repository: Repository?
    struct Repository: Decodable {
        let pullRequest: PRReviewStatePayload?
    }
}

/// Decoded payload for the `pullRequest` field of `fetchPRReviewState`.
struct PRReviewStatePayload: Decodable {
    /// Head branch name from `headRefName` (e.g. `feature/PROJ-123`).
    /// Nil when the field is absent in the response.
    let headRefName: String?
    let reviewRequests: ReviewRequests?
    let latestReviews: LatestReviews?
    let reviewThreads: ReviewThreads?

    /// Memberwise init for tests. `headRefName` defaults to nil so existing
    /// test call sites that pre-date this field don't need to change.
    init(
        headRefName: String? = nil,
        reviewRequests: ReviewRequests?,
        latestReviews: LatestReviews?,
        reviewThreads: ReviewThreads?
    ) {
        self.headRefName = headRefName
        self.reviewRequests = reviewRequests
        self.latestReviews = latestReviews
        self.reviewThreads = reviewThreads
    }

    struct ReviewRequests: Decodable {
        let nodes: [Node]
        struct Node: Decodable {
            let requestedReviewer: RequestedReviewer?
        }
    }

    struct LatestReviews: Decodable {
        let nodes: [Node]
        struct Node: Decodable {
            let state: String
            let author: Author?
        }
    }

    struct Author: Decodable {
        let login: String
        /// Present on `User` actor fragments (`... on User { avatarUrl }`).
        /// Nil for non-User actors (bots, teams) or when the fragment is absent.
        let avatarUrl: String?

        /// Convenience init for tests that only need `login`.
        init(login: String, avatarUrl: String? = nil) {
            self.login = login
            self.avatarUrl = avatarUrl
        }
    }

    struct ReviewThreads: Decodable {
        let totalCount: Int?
        let nodes: [Thread]
        struct Thread: Decodable {
            let isResolved: Bool
            let comments: ThreadComments?
        }
        struct ThreadComments: Decodable {
            let totalCount: Int?
            let nodes: [ThreadComment]
        }
        struct ThreadComment: Decodable {
            let author: Author?
        }
    }
}

/// Discriminated `RequestedReviewer` (`User` or `Team`). GitHub returns either
/// shape depending on `__typename`.
enum RequestedReviewer: Decodable, Hashable {
    /// A GitHub user reviewer. `avatarUrl` comes from the `... on User { avatarUrl }` fragment.
    case user(login: String, avatarUrl: String?)
    case team(name: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
        case name
        case avatarUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .typename) ?? ""
        switch type {
        case "User":
            let login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
            let avatarUrl = try c.decodeIfPresent(String.self, forKey: .avatarUrl)
            self = .user(login: login, avatarUrl: avatarUrl)
        case "Team":
            let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            self = .team(name: name)
        default:
            self = .unknown
        }
    }
}

// MARK: - State mapping

/// Maps a GitHub review state string to our `ReviewerStatus`. Unknown states
/// fall back to `.commented` (the safest non-blocking interpretation,
/// matching how `index.html` treats anything that isn't APPROVED/CHANGES_REQUESTED).
private func mapReviewState(_ raw: String) -> ReviewerStatus {
    switch raw {
    case "APPROVED": return .approved
    case "CHANGES_REQUESTED": return .changesRequested
    case "COMMENTED": return .commented
    case "DISMISSED": return .dismissed
    case "PENDING": return .pending
    default: return .commented
    }
}

private struct ReviewerEntryBuilder {
    let login: String
    var status: ReviewerStatus
    var reRequested: Bool
    var avatarURL: URL?
}
