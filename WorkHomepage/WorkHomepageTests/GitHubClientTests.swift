//
//  GitHubClientTests.swift
//  WorkHomepageTests
//
//  Stubs URLSession via URLProtocol to exercise GitHubClient happy + error paths.
//

import XCTest
@testable import WorkHomepage

@MainActor
final class GitHubClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testHappyPathDecodesItems() async throws {
        let body = """
        {
          "items": [
            {
              "id": 101,
              "number": 7,
              "title": "Add cool feature",
              "html_url": "https://github.com/Ala-com/foo/pull/7",
              "user": { "login": "octocat" },
              "repository_url": "https://api.github.com/repos/Ala-com/foo"
            }
          ]
        }
        """
        StubURLProtocol.responder = { _ in
            let data = body.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/search/issues")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, data)
        }

        let client = GitHubClient(
            session: makeSession(),
            tokenProvider: { "fake-token" },
            onUnauthorized: {}
        )
        let prs = try await client.fetchReviewRequestedPRs()
        XCTAssertEqual(prs.count, 1)
        let pr = prs[0]
        XCTAssertEqual(pr.id, 101)
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.title, "Add cool feature")
        XCTAssertEqual(pr.user.login, "octocat")
        XCTAssertEqual(pr.repoFullName, "Ala-com/foo")
    }

    func testUnauthorizedClearsTokenAndThrows() async {
        StubURLProtocol.responder = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/search/issues")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("unauthorized".utf8))
        }

        var clearCalled = false
        let client = GitHubClient(
            session: makeSession(),
            tokenProvider: { "stale-token" },
            onUnauthorized: { clearCalled = true }
        )

        do {
            _ = try await client.fetchReviewRequestedPRs()
            XCTFail("Expected GitHubError.unauthorized")
        } catch GitHubError.unauthorized {
            XCTAssertTrue(clearCalled, "onUnauthorized should fire on 401")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testNon2xxThrowsHttpError() async {
        StubURLProtocol.responder = { _ in
            let response = HTTPURLResponse(
                url: URL(string: "https://api.github.com/search/issues")!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("boom".utf8))
        }

        let client = GitHubClient(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )

        do {
            _ = try await client.fetchReviewRequestedPRs()
            XCTFail("Expected GitHubError.http")
        } catch GitHubError.http(let status, let body) {
            XCTAssertEqual(status, 500)
            XCTAssertEqual(body, "boom")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testMissingTokenThrowsBeforeRequest() async {
        let client = GitHubClient(
            session: makeSession(),
            tokenProvider: { nil },
            onUnauthorized: {}
        )
        do {
            _ = try await client.fetchReviewRequestedPRs()
            XCTFail("Expected GitHubError.missingToken")
        } catch GitHubError.missingToken {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }
}

// MARK: - URLProtocol stub

final class StubURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var responder: Responder?

    static func reset() {
        responder = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = StubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "StubURLProtocol", code: -1))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
