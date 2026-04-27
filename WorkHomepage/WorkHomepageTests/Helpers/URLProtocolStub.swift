//
//  URLProtocolStub.swift
//  WorkHomepageTests
//
//  Single, capability-rich `URLProtocol` stub. Replaces five per-file copies
//  (`StubURLProtocol`, `JiraStubURLProtocol`, `JiraCacheStubURLProtocol`,
//  `AvatarStubURLProtocol`, `WorkflowsStubURLProtocol`) so transport-failure
//  injection, header injection, and multi-response sequencing are all
//  reachable from any test without re-implementing the plumbing.
//
//  Usage patterns:
//
//  1. Single-response responder (REST happy / error):
//     ```
//     URLProtocolStub.respond { req in
//         (HTTPURLResponse(...), Data(...))
//     }
//     ```
//
//  2. Transport failure (timeout / connection drop):
//     ```
//     URLProtocolStub.failWith(URLError(.timedOut))
//     ```
//     Calls under this stub trip `URLSessionDelegate` failure with the supplied
//     `URLError` — exercises the retry / typed-error path in `HTTPClient`.
//
//  3. Multi-response sequence (e.g. retry-then-succeed):
//     ```
//     URLProtocolStub.responses = [
//         .failure(URLError(.timedOut)),
//         .success(http200, body)
//     ]
//     ```
//     Each request consumes one entry. Past the end, the stub returns the
//     last response (the test asserts how many times the sequence was hit).
//
//  4. Header injection: `respond` returns a fully-formed `HTTPURLResponse`,
//     so callers attach whatever `X-RateLimit-Remaining` / `Retry-After` /
//     `ETag` they need by passing a `headerFields` dictionary.
//
//  Reset between tests via `URLProtocolStub.reset()`.
//

import Foundation

final class URLProtocolStub: URLProtocol {

    // MARK: - Response shape

    enum Response {
        /// Successful HTTP response with the supplied body. The
        /// `HTTPURLResponse` carries whatever headers the test set up.
        case success(HTTPURLResponse, Data)
        /// Transport failure. URLSession will surface this as a `URLError`
        /// in the consumer.
        case failure(Error)
    }

    typealias Responder = (URLRequest) -> Response

    // MARK: - Stub state (per-process)

    /// Single-shot responder. If non-nil, every request runs through this
    /// closure and the `responses` array is ignored.
    nonisolated(unsafe) static var responder: Responder?

    /// Sequenced responses. First entry serves the first request, etc.
    /// Once the array is exhausted, the LAST entry is replayed for any
    /// further requests so a test can assert "we made >= N retries" by
    /// reading `requestCount`.
    nonisolated(unsafe) static var responses: [Response] = []

    /// Number of `startLoading()` calls observed in this run. Reset alongside
    /// the responder; tests use it to assert retries fired.
    nonisolated(unsafe) static var requestCount: Int = 0

    /// All requests observed, captured for tests that need to verify URL /
    /// method / body shape.
    nonisolated(unsafe) static var observedRequests: [URLRequest] = []

    static func reset() {
        responder = nil
        responses = []
        requestCount = 0
        observedRequests = []
    }

    // MARK: - Convenience setters

    /// Pin a single responder closure. Cleanest for happy-path / error-path
    /// REST tests where the response depends on the request URL.
    static func respond(_ closure: @escaping Responder) {
        responder = closure
    }

    /// Pin every request to fail with the supplied URLError. Used for the
    /// `URLError.timedOut` / `.networkConnectionLost` retry paths.
    static func failWith(_ error: Error) {
        responder = { _ in .failure(error) }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        URLProtocolStub.requestCount += 1
        URLProtocolStub.observedRequests.append(request)

        let response: URLProtocolStub.Response
        if let responder = URLProtocolStub.responder {
            response = responder(request)
        } else if !URLProtocolStub.responses.isEmpty {
            // Pick from the sequence; clamp to the last entry once exhausted.
            let idx = min(URLProtocolStub.requestCount - 1, URLProtocolStub.responses.count - 1)
            response = URLProtocolStub.responses[idx]
        } else {
            // Default: 500 with empty body so an unconfigured stub is a loud
            // failure rather than a silent hang.
            let http = HTTPURLResponse(
                url: request.url ?? URL(string: "about:blank")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            response = .success(http, Data("URLProtocolStub: no responder configured".utf8))
        }

        switch response {
        case .success(let http, let data):
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    // MARK: - Convenience builders

    /// Build a fully-formed `HTTPURLResponse` for the supplied URL with optional
    /// status / headers. Saves boilerplate at every call site.
    static func http(
        _ status: Int = 200,
        url: URL = URL(string: "https://api.github.com/")!,
        headers: [String: String]? = nil
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    /// Build an `URLSessionConfiguration.ephemeral` wired to this stub.
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }
}
