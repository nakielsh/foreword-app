//
//  GitHubHTTPClientErrorTests.swift
//  WorkHomepageTests
//
//  Coverage gaps in the typed-error surface of `GitHubError`:
//
//   1. 403 with `X-RateLimit-Remaining: 0` + `X-RateLimit-Reset: <future>`
//      → `.rateLimited(resetAt:isSecondary: false)` with the parsed reset.
//   2. 429 + `Retry-After: <seconds>` → `.rateLimited(resetAt:isSecondary: true)`.
//   3. `URLError(.timedOut)` retried twice then surfaced as `.transport`.
//   4. `URLError(.networkConnectionLost)` likewise.
//   5. Malformed JSON on a 200 → `.decoding` carrying `codingPath` + a body
//      snippet (the production diagnostic shape).
//
//  Each test goes through the real `HTTPClient` (via `GitHubClient`) wired
//  to `URLProtocolStub` — the unified stub gained sequenced-response and
//  transport-failure injection precisely for these paths.
//

import XCTest
@testable import WorkHomepage

@MainActor
final class GitHubHTTPClientErrorTests: XCTestCase {

    override func setUp() {
        super.setUp()
        URLProtocolStub.reset()
    }

    override func tearDown() {
        URLProtocolStub.reset()
        super.tearDown()
    }

    private func makeClient() -> GitHubClient {
        GitHubClient(
            session: URLProtocolStub.makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
    }

    // MARK: - 403 + X-RateLimit-Remaining: 0 → primary rate limit

    func testPrimaryRateLimit403CarriesResetAt() async {
        let resetEpoch = Date().addingTimeInterval(120).timeIntervalSince1970
        let resetStr = String(Int(resetEpoch))
        URLProtocolStub.respond { req in
            let http = URLProtocolStub.http(
                403,
                url: req.url!,
                headers: [
                    "X-RateLimit-Remaining": "0",
                    "X-RateLimit-Reset": resetStr
                ]
            )
            return .success(http, Data("{\"message\":\"API rate limit exceeded\"}".utf8))
        }

        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected rateLimited error")
        } catch GitHubError.rateLimited(let resetAt, let isSecondary) {
            assertThat(isSecondary).isFalse()
            // Within 2s of the reset we set up.
            let delta = abs(resetAt.timeIntervalSince1970 - resetEpoch)
            assertThat(delta).isLessThan(2)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - 429 + Retry-After → secondary rate limit

    func testSecondaryRateLimit429RetryAfterCarriesResetAt() async {
        URLProtocolStub.respond { req in
            let http = URLProtocolStub.http(
                429,
                url: req.url!,
                headers: ["Retry-After": "30"]
            )
            return .success(http, Data("{\"message\":\"abuse limit\"}".utf8))
        }

        let before = Date()
        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected rateLimited error")
        } catch GitHubError.rateLimited(let resetAt, let isSecondary) {
            assertThat(isSecondary).isTrue()
            // Reset is approximately now+30s.
            let secondsAhead = resetAt.timeIntervalSince(before)
            assertThat(secondsAhead).isGreaterThanOrEqualTo(28)
            assertThat(secondsAhead).isLessThanOrEqualTo(35)
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - URLError(.timedOut) retried then surfaced

    func testTimedOutRetriesThenSurfacesTransport() async {
        URLProtocolStub.failWith(URLError(.timedOut))

        let start = Date()
        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected transport error")
        } catch GitHubError.transport {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)

        // HTTPClient retryDelays = [0.5, 2.0, 5.0] → 2 retries before
        // surfacing. Total minimum elapsed ~7.5s. We cap at 15s for slop.
        // URLSession may add its own internal retry on timeouts (it does
        // for `URLError.timedOut` via `shouldRetryConnectionFailure`), so
        // we assert ">= 3 attempts" instead of "== 3" — three is the
        // HTTPClient lower bound, anything more is URLSession's choice.
        assertThat(elapsed).isGreaterThanOrEqualTo(7)
        assertThat(elapsed).isLessThan(20)
        assertThat(URLProtocolStub.requestCount).isGreaterThanOrEqualTo(3)
    }

    // MARK: - URLError(.networkConnectionLost) retried then surfaced

    func testNetworkConnectionLostRetriesThenSurfacesTransport() async {
        URLProtocolStub.failWith(URLError(.networkConnectionLost))

        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected transport error")
        } catch GitHubError.transport {
            // expected
        } catch {
            XCTFail("wrong error: \(error)")
        }
        // 1 original + 2 retries — same URLSession-internal-retry caveat
        // as `testTimedOutRetriesThenSurfacesTransport`, so >= 3.
        assertThat(URLProtocolStub.requestCount).isGreaterThanOrEqualTo(3)
    }

    // MARK: - Malformed JSON on 200 → typed .decoding with codingPath + body

    func testMalformedJSONOn200ThrowsTypedDecodingError() async {
        // Body is technically a JSON object but the schema expects
        // `{ "items": [...] }` — `items` is missing. The decoder should
        // surface a key-not-found error with `codingPath` + body snippet.
        let body = #"{"unexpected_root_key":[]}"#
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(200, url: req.url!), Data(body.utf8))
        }

        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected decoding error")
        } catch GitHubError.decoding(let detail) {
            // The diagnostic must carry a coding-path label and a snippet
            // of the body so production failures are debuggable.
            assertThat(detail).contains("codingPath")
            assertThat(detail).contains("body[0..<1KB]")
            assertThat(detail).contains("unexpected_root_key")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    // MARK: - Genuinely-corrupted JSON on 200 → typed .decoding

    func testGarbageBodyOn200ThrowsTypedDecodingError() async {
        let body = "this is not json at all"
        URLProtocolStub.respond { req in
            .success(URLProtocolStub.http(200, url: req.url!), Data(body.utf8))
        }

        do {
            _ = try await makeClient().fetchReviewRequestedPRs()
            XCTFail("expected decoding error")
        } catch GitHubError.decoding(let detail) {
            assertThat(detail).contains("body[0..<1KB]")
            assertThat(detail).contains("this is not json")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
