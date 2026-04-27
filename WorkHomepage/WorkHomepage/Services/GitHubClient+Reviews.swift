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
//  All HTTP plumbing (auth headers, retries, ETag, rate-limit, decode
//  errors) lives in `HTTPClient.swift`. This file is a thin layer over
//  `HTTPClient.getDecoded` / `paginate` plus per-PR derivation logic.
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

    private var http: HTTPClient {
        HTTPClient(
            session: session,
            tokenProvider: tokenProvider,
            onUnauthorized: onUnauthorized
        )
    }

    // MARK: - Pending review PRs

    func fetchPendingReviewPRs(currentUser: String) async throws -> [PendingReviewPR] {
        let q = "is:pr+is:open+review-requested:@me"
        let urlString = "https://api.github.com/search/issues?q=\(q)&sort=updated&order=desc&per_page=100"
        let items: [ReviewsSearchPR] = try await searchPRs(urlString: urlString)

        var out: [PendingReviewPR] = []
        out.reserveCapacity(items.count)
        for pr in items {
            let reviews: [PRReviewDTO]
            do {
                reviews = try await fetchPRReviews(repo: pr.repoFullName, number: pr.number)
            } catch {
                // index.html parity: per-PR failure becomes empty review set.
                // TODO(networking-followup): surface a per-card error indicator
                // so "fetch failed" is distinguishable from "no reviews".
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
                branchRef: nil,
                headSha: nil,
                authorAvatarURL: pr.user.avatarURL,
                reviewerEntries: []
            ))
        }
        return out
    }

    // MARK: - Reviewed-by-me PRs

    func fetchReviewedByMePRs(currentUser: String) async throws -> [ReviewedPR] {
        let q = "is:pr+is:open+reviewed-by:@me+-author:@me"
        let urlString = "https://api.github.com/search/issues?q=\(q)&sort=updated&order=desc&per_page=100"
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
                // TODO(networking-followup): surface a per-card error indicator
                // so "fetch failed" is distinguishable from "no reviews".
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
                branchRef: nil,
                headSha: nil,
                authorAvatarURL: pr.user.avatarURL,
                reviewerEntries: []
            ))
        }
        return out
    }

    // MARK: - Per-PR REST helpers (internal so tests can hit them)

    func fetchPRReviews(repo: String, number: Int) async throws -> [PRReviewDTO] {
        let url = "https://api.github.com/repos/\(repo)/pulls/\(number)/reviews?per_page=100"
        return try await http.getDecoded([PRReviewDTO].self, urlString: url)
    }

    func fetchPRCommits(repo: String, number: Int) async throws -> [PRCommitDTO] {
        let url = "https://api.github.com/repos/\(repo)/pulls/\(number)/commits?per_page=100"
        return try await http.getDecoded([PRCommitDTO].self, urlString: url)
    }

    // MARK: - Search helper

    private func searchPRs(urlString: String) async throws -> [ReviewsSearchPR] {
        let envelope: SearchEnvelope = try await http.getDecoded(SearchEnvelope.self, urlString: urlString)
        return envelope.items
    }
}

// MARK: - Search envelope

private struct SearchEnvelope: Decodable {
    let items: [ReviewsSearchPR]
}
