//
//  GitHubClient+Reviews.swift
//  WorkHomepage
//
//  Slice 02 — Reviews tab full parity.
//
//  Sidecar for the Reviews tab. Same pattern as `GitHubClient+MyPRs.swift`:
//  the slice 01 `GitHubClient` keeps its session/tokenProvider/onUnauthorized
//  as `private`, so an extension in another file cannot reuse them. We expose
//  thin convenience methods on `GitHubClient` that delegate to a co-located
//  `ReviewsAPI` struct, which owns its own URLSession plumbing and is what
//  unit tests instantiate with a stubbed session.
//
//  Two operations:
//    - `fetchPendingReviewPRs(currentUser:)` — REST search
//      `is:pr+is:open+review-requested:@me` then per-PR `pulls/{n}/reviews`
//      to compute approval count and detect dismissed-by-me state.
//    - `fetchReviewedByMePRs(currentUser:)` — REST search
//      `is:pr+is:open+reviewed-by:@me+-author:@me` then per-PR reviews + commits
//      to derive `myLastReviewState`, `myLastReviewSubmittedAt`, and
//      `newCommitsSinceReview`.
//
//  Both methods accept the current-user login as a parameter, matching the
//  same explicit-parameter style `MyPRsAPI.fetchPRReviewState` uses for the
//  same reason — derivations depend on it, and accepting it from the caller
//  keeps tests deterministic.
//

import struct Foundation.URL
import struct Foundation.URLRequest
import class Foundation.URLSession
import class Foundation.HTTPURLResponse
import class Foundation.URLResponse
import class Foundation.JSONDecoder
import struct Foundation.Data

// MARK: - Public surface on GitHubClient

extension GitHubClient {
    /// Fetches PRs awaiting your review (`review-requested:@me`), enriched
    /// with derived `approvalCount`, `isDraft`, `isDismissed`, and
    /// `myPriorReviewState`.
    func fetchPendingReviewPRs(currentUser: String) async throws -> [PendingReviewPR] {
        try await ReviewsAPI.default().fetchPendingReviewPRs(currentUser: currentUser)
    }

    /// Fetches PRs you previously reviewed and are still open. Each entry
    /// carries `myLastReviewState`, `myLastReviewSubmittedAt`, and
    /// `newCommitsSinceReview` so the view can split them across the three
    /// sub-sections (Changes Requested / My Comments / Already Approved) and
    /// render the "+N new commits since your review" badge.
    func fetchReviewedByMePRs(currentUser: String) async throws -> [ReviewedPR] {
        try await ReviewsAPI.default().fetchReviewedByMePRs(currentUser: currentUser)
    }
}

// MARK: - Sidecar struct

struct ReviewsAPI {
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

    /// Production defaults: shared session + Keychain token + 401-clears-keychain.
    static func `default`() -> ReviewsAPI { ReviewsAPI() }

    // MARK: - Pending review PRs

    func fetchPendingReviewPRs(currentUser: String) async throws -> [PendingReviewPR] {
        let q = "is:pr+is:open+review-requested:@me"
        let urlString = "https://api.github.com/search/issues?q=\(q)&sort=updated&order=desc&per_page=50"
        let items: [ReviewsSearchPR] = try await searchPRs(urlString: urlString)

        var out: [PendingReviewPR] = []
        out.reserveCapacity(items.count)
        for pr in items {
            let reviews: [PRReviewDTO]
            do {
                reviews = try await fetchPRReviews(repo: pr.repoFullName, number: pr.number)
            } catch {
                // index.html parity: per-PR failure becomes empty review set.
                reviews = []
            }
            let approvals = ReviewsDerive.approvalCount(reviews: reviews)
            let changes = ReviewsDerive.changesRequestedCount(reviews: reviews)
            let isDismissed = ReviewsDerive.isDismissedByMe(reviews: reviews, login: currentUser)
            let priorState = ReviewsDerive.myLastReviewState(reviews: reviews, login: currentUser)
            out.append(PendingReviewPR(
                id: pr.id,
                number: pr.number,
                title: pr.title,
                htmlURL: pr.htmlURL,
                authorLogin: pr.user.login,
                repoFullName: pr.repoFullName,
                createdAt: pr.createdAt,
                isDraft: pr.draft ?? false,
                approvalCount: approvals,
                changesRequestedCount: changes,
                isDismissed: isDismissed,
                myPriorReviewState: priorState,
                branchRef: nil
            ))
        }
        return out
    }

    // MARK: - Reviewed-by-me PRs

    func fetchReviewedByMePRs(currentUser: String) async throws -> [ReviewedPR] {
        let q = "is:pr+is:open+reviewed-by:@me+-author:@me"
        let urlString = "https://api.github.com/search/issues?q=\(q)&sort=updated&order=desc&per_page=50"
        let items: [ReviewsSearchPR] = try await searchPRs(urlString: urlString)

        var out: [ReviewedPR] = []
        out.reserveCapacity(items.count)
        for pr in items {
            let reviews: [PRReviewDTO]
            let commits: [PRCommitDTO]
            do {
                async let r = fetchPRReviews(repo: pr.repoFullName, number: pr.number)
                async let c = fetchPRCommits(repo: pr.repoFullName, number: pr.number)
                (reviews, commits) = try await (r, c)
            } catch {
                reviews = []
                commits = []
            }
            let myState = ReviewsDerive.myLastReviewState(reviews: reviews, login: currentUser) ?? .commented
            let mySubmitted = ReviewsDerive.myLastReviewSubmittedAt(reviews: reviews, login: currentUser)
            let newCommits = ReviewsDerive.newCommitsSinceReview(commits: commits, since: mySubmitted)
            let approvals = ReviewsDerive.approvalCount(reviews: reviews)
            let changes = ReviewsDerive.changesRequestedCount(reviews: reviews)
            out.append(ReviewedPR(
                id: pr.id,
                number: pr.number,
                title: pr.title,
                htmlURL: pr.htmlURL,
                authorLogin: pr.user.login,
                repoFullName: pr.repoFullName,
                createdAt: pr.createdAt,
                isDraft: pr.draft ?? false,
                approvalCount: approvals,
                changesRequestedCount: changes,
                myLastReviewState: myState,
                myLastReviewSubmittedAt: mySubmitted,
                newCommitsSinceReview: newCommits,
                branchRef: nil
            ))
        }
        return out
    }

    // MARK: - Per-PR REST helpers (internal so tests can hit them)

    func fetchPRReviews(repo: String, number: Int) async throws -> [PRReviewDTO] {
        let url = "https://api.github.com/repos/\(repo)/pulls/\(number)/reviews?per_page=100"
        return try await getDecoded([PRReviewDTO].self, urlString: url)
    }

    func fetchPRCommits(repo: String, number: Int) async throws -> [PRCommitDTO] {
        let url = "https://api.github.com/repos/\(repo)/pulls/\(number)/commits?per_page=100"
        return try await getDecoded([PRCommitDTO].self, urlString: url)
    }

    // MARK: - Generic helpers

    private func searchPRs(urlString: String) async throws -> [ReviewsSearchPR] {
        let envelope: SearchEnvelope = try await getDecoded(SearchEnvelope.self, urlString: urlString)
        return envelope.items
    }

    private func getDecoded<T: Decodable>(_ type: T.Type, urlString: String) async throws -> T {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }
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
            return try decoder.decode(T.self, from: data)
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

// MARK: - Search envelope

private struct SearchEnvelope: Decodable {
    let items: [ReviewsSearchPR]
}
