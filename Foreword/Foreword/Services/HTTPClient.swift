//
//  HTTPClient.swift
//  Foreword
//
//  Shared HTTP layer for the five `GitHubClient*` files. Centralises
//  performRequest + checkResponse + auth headers + decoder config so
//  drift (like the inconsistent `dateDecodingStrategy = .iso8601`)
//  cannot happen again. Adds:
//    - ETag / If-None-Match via a shared URLCache. 304 responses
//      transparently serve the cached body.
//    - Rate-limit awareness (`X-RateLimit-Remaining` / `…-Reset`,
//      `Retry-After`) surfaced as `GitHubError.rateLimited`.
//    - Retry with backoff (0.5s, 2s, 5s) for transient 5xx and
//      `URLError.networkConnectionLost` / `.timedOut` /
//      `.notConnectedToInternet`. 4xx is never retried (except 429
//      on Retry-After-driven secondary limits).
//    - Decode-error context: `codingPath` + 1KB body snippet.
//    - Pagination via `Link: rel="next"` with a 5-page ceiling.
//

import struct Foundation.Data
import struct Foundation.Date
import struct Foundation.TimeInterval
import struct Foundation.URL
import struct Foundation.URLComponents
import struct Foundation.URLQueryItem
import struct Foundation.URLRequest
import class Foundation.URLCache
import class Foundation.URLSession
import class Foundation.URLResponse
import class Foundation.HTTPURLResponse
import class Foundation.JSONDecoder
import class Foundation.NSLock
import struct Foundation.URLError
import class Foundation.CachedURLResponse

// MARK: - GitHubError (extended)

/// Errors raised by every GitHubClient* file. Cases are additive vs the
/// slice-01 shape so existing call sites that match `unauthorized` /
/// `missingToken` / `http` / `decoding` / `transport` keep working.
enum GitHubError: Error, Equatable {
    case missingToken
    case unauthorized
    case http(status: Int, body: String)
    case decoding(String)
    case transport(String)
    /// Primary or secondary rate limit. `isSecondary` means we got a
    /// `Retry-After` (abuse-detection / abuse-rate-limit), not a clock
    /// reset. Schedulers should honour `resetAt` and not auto-retry.
    case rateLimited(resetAt: Date, isSecondary: Bool)
    /// 403 that is *not* a rate limit (auth scope / SSO / org policy).
    case forbidden(body: String)
    /// 404. Pulled out so call sites can branch without string-matching.
    case notFound(body: String)
    /// GraphQL 200-with-errors and *no* `data` field. When `data` is
    /// present we log and return it — callers never see this case for
    /// partial responses.
    case graphqlPartial(errors: [String])
}

// MARK: - Shared URLCache

/// Lazy singleton URLCache used by all GitHubClient* requests. 64 MB on
/// disk, 16 MB in memory; sized to comfortably hold a multi-day session
/// of reviewed PRs without eviction churn. Shared so ETag-driven 304
/// responses can re-use the cached body across the five clients.
enum GitHubURLCache {
    static let shared: URLCache = {
        let memCap = 16 * 1024 * 1024
        let diskCap = 64 * 1024 * 1024
        return URLCache(memoryCapacity: memCap, diskCapacity: diskCap, diskPath: "github-http-cache")
    }()
}

// MARK: - HTTPClient

/// Single HTTP helper used by every GitHubClient* file. Stateless
/// from the caller's perspective — pass a session + token + 401
/// callback and it returns decoded JSON (or throws a typed error).
struct HTTPClient {
    /// Default per-request timeout. URLSession's default is 60s, which on
    /// a long-running app means a stuck socket can pin a refresh for a
    /// full minute. 15s is comfortably above GitHub's p99.
    static let defaultRequestTimeout: TimeInterval = 15

    /// Max retry attempts for transient failures (5xx + select URLErrors).
    /// 2 retries = 3 total attempts. Backoff: 0.5s, 2s, 5s (per attempt).
    static let retryDelays: [TimeInterval] = [0.5, 2.0, 5.0]

    /// Pagination ceiling for `paginate(...)`. Keeps a misbehaving
    /// `Link: rel="next"` chain from looping forever.
    static let maxPaginationPages: Int = 5

    private let session: URLSession
    private let tokenProvider: () -> String?
    private let onUnauthorized: () -> Void
    private let cache: URLCache

    init(
        session: URLSession,
        tokenProvider: @escaping () -> String?,
        onUnauthorized: @escaping () -> Void,
        cache: URLCache = GitHubURLCache.shared
    ) {
        self.session = session
        self.tokenProvider = tokenProvider
        self.onUnauthorized = onUnauthorized
        self.cache = cache
    }

    // MARK: - Public surface

    /// GET `urlString` and decode the body as `T`. Adds auth + Accept +
    /// API-version headers, follows the retry/backoff policy, parses
    /// rate-limit headers, and serves cached bodies on 304.
    func getDecoded<T: Decodable>(_ type: T.Type, urlString: String) async throws -> T {
        let request = try makeAuthorizedGET(urlString: urlString)
        let data = try await execute(request)
        return try decode(T.self, from: data)
    }

    /// GET `urlString` and return the raw body. Used when the caller
    /// needs to inspect headers or skip JSON decoding.
    func getData(urlString: String) async throws -> Data {
        let request = try makeAuthorizedGET(urlString: urlString)
        return try await execute(request)
    }

    /// GET `urlString` and return the decoded body plus the response
    /// headers. Used by envelope-shaped paginated endpoints (e.g.
    /// `/actions/workflows`) that need to read `Link: rel="next"`.
    func getDecodedWithHeaders<T: Decodable>(
        _ type: T.Type,
        urlString: String
    ) async throws -> (T, [String: String]) {
        let request = try makeAuthorizedGET(urlString: urlString)
        let (data, headers) = try await executeWithHeaders(request)
        let decoded = try decode(T.self, from: data)
        return (decoded, headers)
    }

    /// POST `body` to `urlString` and decode `T`. Used by GraphQL.
    func postDecoded<T: Decodable>(
        _ type: T.Type,
        urlString: String,
        body: Data,
        contentType: String = "application/json"
    ) async throws -> T {
        let request = try makeAuthorizedPOST(
            urlString: urlString,
            body: body,
            contentType: contentType
        )
        let data = try await execute(request)
        return try decode(T.self, from: data)
    }

    // MARK: - Pagination

    /// Walks `Link: rel="next"` starting from `urlString`, decoding each
    /// page as `[T]` and accumulating. Stops at `maxPaginationPages` to
    /// guard against runaway servers. Honours the same retry / 304 /
    /// rate-limit policy as `getDecoded`.
    func paginate<T: Decodable>(
        _ type: T.Type,
        urlString: String,
        maxPages: Int = HTTPClient.maxPaginationPages
    ) async throws -> [T] {
        var collected: [T] = []
        var nextURL: String? = urlString
        var pages = 0
        while let current = nextURL, pages < maxPages {
            let request = try makeAuthorizedGET(urlString: current)
            let (data, headers) = try await executeWithHeaders(request)
            let page: [T] = try decode([T].self, from: data)
            collected.append(contentsOf: page)
            nextURL = HTTPClient.parseNextLink(headers["Link"])
            pages += 1
        }
        return collected
    }

    /// Pull out `<...>; rel="next"` from a `Link` header, if present.
    /// Exposed as `static` so tests can pin the parser directly.
    static func parseNextLink(_ header: String?) -> String? {
        guard let header, !header.isEmpty else { return nil }
        // Header shape: `<url1>; rel="next", <url2>; rel="last"`
        // Spec is comma-separated, but the URL itself never contains
        // an unencoded comma, so a plain split is safe.
        for raw in header.split(separator: ",") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            if part.contains("rel=\"next\"") {
                if let lt = part.firstIndex(of: "<"), let gt = part.firstIndex(of: ">"), lt < gt {
                    let after = part.index(after: lt)
                    return String(part[after..<gt])
                }
            }
        }
        return nil
    }

    // MARK: - Request building

    private func makeAuthorizedGET(urlString: String) throws -> URLRequest {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = HTTPClient.defaultRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        // ETag — pull from our shared cache and forward If-None-Match.
        // URLSession's own validator will be used too, but we set the
        // header explicitly so the policy is identical regardless of
        // session-level cache configuration.
        if let cached = cache.cachedResponse(for: request),
           let httpResp = cached.response as? HTTPURLResponse,
           let etag = HTTPClient.headerValue(httpResp, name: "ETag") {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        return request
    }

    private func makeAuthorizedPOST(
        urlString: String,
        body: Data,
        contentType: String
    ) throws -> URLRequest {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL: \(urlString)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = HTTPClient.defaultRequestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    // MARK: - Execute (with retries + 304 + rate limits)

    /// Run `request` with the retry/backoff/304/rate-limit policy and
    /// return the body. Throws typed GitHubError cases.
    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, _) = try await executeWithHeaders(request)
        return data
    }

    private func executeWithHeaders(_ request: URLRequest) async throws -> (Data, [String: String]) {
        var attempt = 0
        var lastError: Error?
        while attempt <= HTTPClient.retryDelays.count {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw GitHubError.transport("Non-HTTP response")
                }

                // 304 Not Modified — serve the cached body.
                if http.statusCode == 304, let cached = cache.cachedResponse(for: request) {
                    GitHub401Counter.shared.recordSuccess()
                    return (cached.data, HTTPClient.headerMap(cached.response as? HTTPURLResponse))
                }

                if http.statusCode == 401 {
                    onUnauthorized()
                    throw GitHubError.unauthorized
                }

                // Rate limits — primary (`X-RateLimit-Remaining: 0`) or
                // secondary (`Retry-After`).
                if let rateLimitError = HTTPClient.rateLimitError(http: http, body: data) {
                    throw rateLimitError
                }

                if http.statusCode == 403 {
                    let body = HTTPClient.bodyString(data)
                    throw GitHubError.forbidden(body: body)
                }
                if http.statusCode == 404 {
                    let body = HTTPClient.bodyString(data)
                    throw GitHubError.notFound(body: body)
                }

                if (200..<300).contains(http.statusCode) {
                    GitHub401Counter.shared.recordSuccess()
                    // Cache the response so subsequent requests can
                    // forward If-None-Match. URLSession may cache too,
                    // but we own this explicitly to keep policy in sync.
                    if let etag = HTTPClient.headerValue(http, name: "ETag"), !etag.isEmpty {
                        let cachedResponse = CachedURLResponse(
                            response: http,
                            data: data,
                            userInfo: nil,
                            storagePolicy: .allowed
                        )
                        cache.storeCachedResponse(cachedResponse, for: request)
                    }
                    return (data, HTTPClient.headerMap(http))
                }

                // Retry on 5xx; otherwise typed http error.
                if (500..<600).contains(http.statusCode), attempt < HTTPClient.retryDelays.count {
                    lastError = GitHubError.http(status: http.statusCode, body: HTTPClient.bodyString(data))
                    try await sleep(seconds: HTTPClient.retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw GitHubError.http(status: http.statusCode, body: HTTPClient.bodyString(data))

            } catch let error as GitHubError {
                // Don't retry typed errors — they're already classified.
                throw error
            } catch let urlError as URLError {
                if HTTPClient.isRetryable(urlError), attempt < HTTPClient.retryDelays.count {
                    lastError = GitHubError.transport(urlError.localizedDescription)
                    try await sleep(seconds: HTTPClient.retryDelays[attempt])
                    attempt += 1
                    continue
                }
                throw GitHubError.transport(urlError.localizedDescription)
            } catch {
                throw GitHubError.transport(error.localizedDescription)
            }
        }
        // Loop exit: we exhausted retries.
        if let lastError = lastError as? GitHubError {
            throw lastError
        }
        throw GitHubError.transport("Exhausted retries")
    }

    private func sleep(seconds: TimeInterval) async throws {
        let nanos = UInt64(seconds * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }

    // MARK: - Decoding

    /// Decode `T` from `data`. Wraps `DecodingError` with a contextual
    /// message including the coding path and a 1KB body snippet — the
    /// raw `String(describing: DecodingError)` strips coding paths in
    /// production builds.
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch let error as DecodingError {
            throw GitHubError.decoding(HTTPClient.formatDecodingError(error, body: data))
        } catch {
            throw GitHubError.decoding(error.localizedDescription)
        }
    }

    /// Format a `DecodingError` with full `codingPath` and a body
    /// snippet so production decode failures are debuggable. Static so
    /// tests can pin the format.
    static func formatDecodingError(_ error: DecodingError, body: Data) -> String {
        let path = HTTPClient.codingPath(error)
        let summary: String
        switch error {
        case .typeMismatch(let type, let ctx):
            summary = "type mismatch: expected \(type) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            summary = "value not found: expected \(type) — \(ctx.debugDescription)"
        case .keyNotFound(let key, let ctx):
            summary = "key not found: \(key.stringValue) — \(ctx.debugDescription)"
        case .dataCorrupted(let ctx):
            summary = "data corrupted: \(ctx.debugDescription)"
        @unknown default:
            summary = "unknown decoding error"
        }
        let snippet = HTTPClient.bodySnippet(body, limit: 1024)
        return "\(summary) at codingPath: [\(path)] — body[0..<1KB]: \(snippet)"
    }

    private static func codingPath(_ error: DecodingError) -> String {
        let context: DecodingError.Context?
        switch error {
        case .typeMismatch(_, let ctx): context = ctx
        case .valueNotFound(_, let ctx): context = ctx
        case .keyNotFound(_, let ctx): context = ctx
        case .dataCorrupted(let ctx): context = ctx
        @unknown default: context = nil
        }
        guard let context else { return "" }
        return context.codingPath.map { key in
            if let i = key.intValue { return "\(i)" }
            return key.stringValue
        }.joined(separator: ".")
    }

    private static func bodySnippet(_ data: Data, limit: Int) -> String {
        if data.isEmpty { return "<empty>" }
        let prefix = data.prefix(limit)
        if let s = String(data: prefix, encoding: .utf8) { return s }
        return "<\(prefix.count) bytes; not utf-8>"
    }

    private static func bodyString(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Header helpers

    private static func headerValue(_ http: HTTPURLResponse, name: String) -> String? {
        // Foundation case-folds header lookups via
        // `value(forHTTPHeaderField:)` only on Apple platforms; we use it
        // here where it's safe.
        if let v = http.value(forHTTPHeaderField: name) { return v }
        let lower = name.lowercased()
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, ks.lowercased() == lower, let vs = v as? String {
                return vs
            }
        }
        return nil
    }

    private static func headerMap(_ http: HTTPURLResponse?) -> [String: String] {
        guard let http else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String { out[ks] = vs }
        }
        return out
    }

    // MARK: - Rate-limit parsing

    /// Returns a `GitHubError.rateLimited` if the response carries
    /// rate-limit headers indicating exhaustion (primary) or a
    /// `Retry-After` (secondary). Otherwise nil.
    static func rateLimitError(http: HTTPURLResponse, body: Data) -> GitHubError? {
        // Secondary: any 4xx with `Retry-After`. GitHub uses 403 + this
        // header for abuse-rate-limit and 429 for client-side limits.
        if let retryAfter = headerValue(http, name: "Retry-After"),
           let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
            let resetAt = Date().addingTimeInterval(seconds)
            return .rateLimited(resetAt: resetAt, isSecondary: true)
        }

        // Primary: `X-RateLimit-Remaining: 0` plus a 4xx (403 or 429).
        if (http.statusCode == 403 || http.statusCode == 429),
           let remaining = headerValue(http, name: "X-RateLimit-Remaining"),
           let remainingInt = Int(remaining),
           remainingInt == 0,
           let resetStr = headerValue(http, name: "X-RateLimit-Reset"),
           let resetEpoch = TimeInterval(resetStr) {
            let resetAt = Date(timeIntervalSince1970: resetEpoch)
            return .rateLimited(resetAt: resetAt, isSecondary: false)
        }
        return nil
    }

    // MARK: - URLError retry classification

    private static func isRetryable(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,
             .timedOut,
             .notConnectedToInternet,
             .dnsLookupFailed,
             .cannotConnectToHost:
            return true
        default:
            return false
        }
    }
}
