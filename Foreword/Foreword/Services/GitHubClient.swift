//
//  GitHubClient.swift
//  Foreword
//
//  URLSession-backed REST client. Slice 01 only exposes review-requested PR fetch.
//
//  All HTTP plumbing now lives in `HTTPClient.swift` — the typed
//  `GitHubError` cases (incl. `rateLimited`, `forbidden`, `notFound`,
//  `graphqlPartial`) and the shared retry / ETag / rate-limit policy
//  are defined there. Each `GitHubClient*` file constructs an
//  `HTTPClient` per call so tests can inject a stubbed `URLSession`.
//

import struct Foundation.Data
import struct Foundation.URL
import struct Foundation.URLRequest
import struct Foundation.TimeInterval
import class Foundation.URLSession
import class Foundation.URLResponse
import class Foundation.HTTPURLResponse
import class Foundation.JSONDecoder
import class Foundation.NSLock

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
    /// Default per-request timeout. Kept here for back-compat with call
    /// sites that read `GitHubClient.defaultRequestTimeout`. The
    /// authoritative value lives on `HTTPClient`.
    static let defaultRequestTimeout: TimeInterval = HTTPClient.defaultRequestTimeout

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
        let urlString = "https://api.github.com/search/issues?q=is:pr+is:open+review-requested:@me&sort=updated&order=desc&per_page=100"
        let http = HTTPClient(
            session: session,
            tokenProvider: tokenProvider,
            onUnauthorized: onUnauthorized
        )
        let envelope = try await http.getDecoded(SearchResponse.self, urlString: urlString)
        return envelope.items
    }

    private struct SearchResponse: Decodable {
        let items: [PullRequest]
    }
}
