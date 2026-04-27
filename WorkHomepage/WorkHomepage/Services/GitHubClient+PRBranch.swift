//
//  GitHubClient+PRBranch.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Sidecar that exposes `GitHubClient.fetchPRBranchInfo(repo:number:)` without
//  touching the slice 01 client (whose URLSession / token plumbing lives
//  behind `private` storage). Same pattern as `GitHubClient+MyPRs.swift` and
//  `GitHubClient+Reviews.swift`: a `PRBranchAPI` struct owns the plumbing,
//  the `GitHubClient` extension is a one-line delegate.
//
//  All HTTP plumbing lives in `HTTPClient.swift`.
//

import struct Foundation.URL
import struct Foundation.URLRequest
import class Foundation.URLSession
import class Foundation.HTTPURLResponse
import class Foundation.URLResponse
import class Foundation.JSONDecoder
import struct Foundation.Data

extension GitHubClient {
    /// Fetches just the head branch + head SHA for a PR. Used by the Review
    /// button to seed `WorktreeManager.prepare`. `repo` is `<org>/<name>`.
    func fetchPRBranchInfo(repo: String, number: Int) async throws -> PRBranchInfo {
        try await PRBranchAPI.default().fetchPRBranchInfo(repo: repo, number: number)
    }
}

// MARK: - Sidecar struct

struct PRBranchAPI {
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

    /// Production defaults: shared session + Keychain-backed token + 401-clears-keychain.
    static func `default`() -> PRBranchAPI { PRBranchAPI() }

    func fetchPRBranchInfo(repo: String, number: Int) async throws -> PRBranchInfo {
        let urlString = "https://api.github.com/repos/\(repo)/pulls/\(number)"
        let http = HTTPClient(
            session: session,
            tokenProvider: tokenProvider,
            onUnauthorized: onUnauthorized
        )
        return try await http.getDecoded(PRBranchInfo.self, urlString: urlString)
    }
}
