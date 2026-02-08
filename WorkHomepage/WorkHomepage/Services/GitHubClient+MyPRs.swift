//
//  GitHubClient+MyPRs.swift
//  WorkHomepage
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

import struct Foundation.URL
import struct Foundation.URLRequest
import class Foundation.URLSession
import class Foundation.HTTPURLResponse
import class Foundation.URLResponse
import class Foundation.JSONDecoder
import class Foundation.JSONSerialization
import struct Foundation.Data

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

    // MARK: - Current user (REST)

    /// Fetches the authenticated user's login from `/user`. The login is
    /// required as input to `fetchPRReviewState` to derive "awaiting you" vs
    /// "awaiting others".
    func fetchCurrentUserLogin() async throws -> String {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }
        guard let url = URL(string: "https://api.github.com/user") else {
            throw GitHubError.transport("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await performRequest(request)
        try checkResponse(response, data: data)

        do {
            let decoded = try JSONDecoder().decode(CurrentUserResponse.self, from: data)
            return decoded.login
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    // MARK: - Authored PRs (REST)

    func fetchAuthoredPRs() async throws -> [AuthoredPR] {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }

        let urlString = "https://api.github.com/search/issues?q=author:@me+is:pr+is:open&sort=updated&order=desc&per_page=50"
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response) = try await performRequest(request)
        try checkResponse(response, data: data)

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(AuthoredSearchResponse.self, from: data)
            return decoded.items
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
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
              reviewRequests(first:20) {
                nodes {
                  requestedReviewer {
                    __typename
                    ... on User { login }
                    ... on Team { name }
                  }
                }
              }
              latestReviews(first:50) {
                nodes {
                  state
                  author { login }
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

        if let firstError = response.errors?.first {
            throw GitHubError.http(status: 200, body: firstError.message)
        }
        guard let pr = response.data?.repository?.pullRequest else {
            throw GitHubError.decoding("Missing pullRequest in GraphQL payload")
        }
        return Self.makePRReviewState(payload: pr, currentUser: currentUser)
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
            if byLogin[login] == nil { order.append(login) }
            byLogin[login] = ReviewerEntryBuilder(login: login, status: status, reRequested: false)
        }

        for node in payload.reviewRequests?.nodes ?? [] {
            guard let reviewer = node.requestedReviewer else { continue }
            let login: String?
            switch reviewer {
            case .user(let login_): login = login_
            case .team(let name): login = name
            case .unknown: login = nil
            }
            guard let login, !login.isEmpty else { continue }
            if var existing = byLogin[login] {
                existing.reRequested = true
                byLogin[login] = existing
            } else {
                order.append(login)
                byLogin[login] = ReviewerEntryBuilder(login: login, status: .pending, reRequested: false)
            }
        }

        let entries = order.compactMap { login -> ReviewerEntry? in
            guard let b = byLogin[login] else { return nil }
            return ReviewerEntry(login: b.login, status: b.status, reRequested: b.reRequested)
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
            totalComments: totalComments
        )
    }

    // MARK: - GraphQL helper (private)

    /// POSTs a GraphQL query/variables pair and decodes a `GraphQLResponse<T>`.
    /// Mirrors REST auth + 401 path so callers see the same `GitHubError` cases.
    private func ghGraphQL<T: Decodable>(
        query: String,
        variables: [String: Any]
    ) async throws -> GraphQLResponse<T> {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }

        guard let url = URL(string: "https://api.github.com/graphql") else {
            throw GitHubError.transport("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let body: [String: Any] = ["query": query, "variables": variables]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw GitHubError.transport("Failed to encode GraphQL body: \(error.localizedDescription)")
        }

        let (data, response) = try await performRequest(request)
        try checkResponse(response, data: data)

        do {
            return try JSONDecoder().decode(GraphQLResponse<T>.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.transport("Non-HTTP response")
        }
        if http.statusCode == 401 {
            onUnauthorized()
            throw GitHubError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(status: http.statusCode, body: body)
        }
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
    let reviewRequests: ReviewRequests?
    let latestReviews: LatestReviews?
    let reviewThreads: ReviewThreads?

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
    case user(login: String)
    case team(name: String)
    case unknown

    private enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
        case name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decodeIfPresent(String.self, forKey: .typename) ?? ""
        switch type {
        case "User":
            let login = try c.decodeIfPresent(String.self, forKey: .login) ?? ""
            self = .user(login: login)
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
}
