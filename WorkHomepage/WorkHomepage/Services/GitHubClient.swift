//
//  GitHubClient.swift
//  WorkHomepage
//
//  URLSession-backed REST client. Slice 01 only exposes review-requested PR fetch.
//

import Foundation

enum GitHubError: Error, Equatable {
    case missingToken
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)
}

struct GitHubClient {
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

    /// Fetches PRs where the authenticated user is a requested reviewer.
    /// Mirrors index.html query: `is:pr+is:open+review-requested:@me`.
    func fetchReviewRequestedPRs() async throws -> [PullRequest] {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }

        let urlString = "https://api.github.com/search/issues?q=is:pr+is:open+review-requested:@me&sort=updated&order=desc&per_page=50"
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
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
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            return decoded.items
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
    }

    private struct SearchResponse: Decodable {
        let items: [PullRequest]
    }
}
