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

/// Counts consecutive 401s observed by GitHub clients before the cached token
/// is wiped. A single spurious 401 (transient proxy glitch, edge-case endpoint
/// returning 401 while others succeed) used to log the user out instantly. Now
/// we require two consecutive failures.
///
/// `recordSuccess()` resets the counter; `recordUnauthorized()` increments and
/// returns true when the threshold is hit.
final class GitHub401Counter: @unchecked Sendable {
    static let shared = GitHub401Counter()
    private let lock = NSLock()
    private var consecutive401s = 0
    /// Threshold above which we wipe the token. 2 means: tolerate one blip.
    private let threshold = 2

    func recordUnauthorized() -> Bool {
        lock.lock()
        consecutive401s += 1
        let trip = consecutive401s >= threshold
        if trip { consecutive401s = 0 }
        lock.unlock()
        return trip
    }

    func recordSuccess() {
        lock.lock()
        consecutive401s = 0
        lock.unlock()
    }

    /// Reset to zero (e.g. after manual token re-entry).
    func reset() {
        lock.lock()
        consecutive401s = 0
        lock.unlock()
    }
}

struct GitHubClient {
    /// Default per-request timeout. URLSession's default is 60s, which on a
    /// long-running app means a stuck socket (sleep/VPN reconnect) can pin a
    /// refresh for a full minute. 15s is comfortably above GitHub's p99 and
    /// short enough that a sleeping Mac doesn't appear hung on resume.
    static let defaultRequestTimeout: TimeInterval = 15

    private let session: URLSession
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void

    init(
        session: URLSession = .shared,
        tokenProvider: @escaping () -> String? = { KeychainStore.get(key: "github.token") },
        onUnauthorized: @escaping () -> Void = {
            // Tolerate one blip — only wipe after two consecutive 401s.
            // Single spurious 401s have been observed for transient
            // proxy/policy glitches; instant logout was painful.
            if GitHub401Counter.shared.recordUnauthorized() {
                KeychainStore.delete(key: "github.token")
            }
        }
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

        if (200..<300).contains(http.statusCode) {
            GitHub401Counter.shared.recordSuccess()
        } else {
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
