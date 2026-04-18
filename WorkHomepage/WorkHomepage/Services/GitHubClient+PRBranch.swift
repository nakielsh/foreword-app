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
        guard let token = tokenProvider() else { throw GitHubError.missingToken }
        let urlString = "https://api.github.com/repos/\(repo)/pulls/\(number)"
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = GitHubClient.defaultRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }
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
        do {
            return try JSONDecoder().decode(PRBranchInfo.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }
}
