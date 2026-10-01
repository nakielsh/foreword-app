//
//  JiraClientTests.swift
//  WorkHomepageTests
//
//  Slice 10. URLProtocol-stubbed tests against `JiraClient.fetchTicket`.
//  Validates basic auth header shape, URL construction, ADF flattening
//  through the full decode path, and error mapping (401 / 404 / other).
//

import XCTest
@testable import WorkHomepage

final class JiraClientTests: XCTestCase {

    override func setUp() {
        super.setUp()
        JiraStubURLProtocol.reset()
    }

    override func tearDown() {
        JiraStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JiraStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(session: URLSession) -> JiraClient {
        JiraClient(
            session: session,
            baseURLProvider: { "https://acme.atlassian.net" },
            emailProvider: { "dev@example.com" },
            tokenProvider: { "secret-token" }
        )
    }

    // MARK: - Happy path

    func testHappyPathDecodesTicket() async throws {
        let body = """
        {
          "key": "PROJ-123",
          "fields": {
            "summary": "Allow PEM-encoded keys",
            "status": { "name": "In Progress" },
            "issuetype": { "name": "Story" },
            "priority": { "name": "High" },
            "description": {
              "type": "doc",
              "version": 1,
              "content": [
                { "type": "paragraph", "content": [ { "type": "text", "text": "First paragraph." } ] },
                { "type": "paragraph", "content": [ { "type": "text", "text": "Second paragraph." } ] }
              ]
            }
          }
        }
        """
        var seenURL: URL?
        var seenAuth: String?
        JiraStubURLProtocol.responder = { request in
            seenURL = request.url
            seenAuth = request.value(forHTTPHeaderField: "Authorization")
            return Self.makeResponse(status: 200, bodyString: body, url: request.url!)
        }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "PROJ-123")

        XCTAssertNotNil(ticket)
        XCTAssertEqual(ticket?.key, "PROJ-123")
        XCTAssertEqual(ticket?.summary, "Allow PEM-encoded keys")
        XCTAssertEqual(ticket?.status, "In Progress")
        XCTAssertEqual(ticket?.issueType, "Story")
        XCTAssertEqual(ticket?.priority, "High")
        XCTAssertNil(ticket?.parentKey)
        XCTAssertEqual(ticket?.description, "First paragraph.\n\nSecond paragraph.")

        // URL contains the requested key and the field projection.
        XCTAssertEqual(seenURL?.host, "acme.atlassian.net")
        XCTAssertEqual(seenURL?.path, "/rest/api/3/issue/PROJ-123")
        let queryItems = URLComponents(url: seenURL!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fieldsItem = queryItems.first { $0.name == "fields" }?.value
        XCTAssertEqual(fieldsItem, "summary,description,status,issuetype,priority,parent")

        // Basic auth header is base64("email:token").
        let expectedCred = "dev@example.com:secret-token".data(using: .utf8)!.base64EncodedString()
        XCTAssertEqual(seenAuth, "Basic \(expectedCred)")
    }

    // MARK: - Subtask with parent

    func testSubtaskExposesParentKey() async throws {
        let body = """
        {
          "key": "PROJ-200",
          "fields": {
            "summary": "Sub-task",
            "status": { "name": "To Do" },
            "issuetype": { "name": "Sub-task" },
            "priority": { "name": "Medium" },
            "parent": { "key": "PROJ-123" },
            "description": null
          }
        }
        """
        JiraStubURLProtocol.responder = { request in
            Self.makeResponse(status: 200, bodyString: body, url: request.url!)
        }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "PROJ-200")

        XCTAssertEqual(ticket?.parentKey, "PROJ-123")
        XCTAssertEqual(ticket?.description, "")
    }

    // MARK: - Bullet list / heading flatten through full path

    func testDescriptionWithHeadingAndBulletsFlattens() async throws {
        let body = """
        {
          "key": "PROJ-300",
          "fields": {
            "summary": "Lists",
            "status": { "name": "Open" },
            "issuetype": { "name": "Bug" },
            "description": {
              "type": "doc", "version": 1, "content": [
                { "type": "heading", "attrs": { "level": 2 },
                  "content": [ { "type": "text", "text": "Repro" } ] },
                { "type": "bulletList", "content": [
                    { "type": "listItem", "content": [
                      { "type": "paragraph", "content": [ { "type": "text", "text": "Step one" } ] }
                    ]},
                    { "type": "listItem", "content": [
                      { "type": "paragraph", "content": [ { "type": "text", "text": "Step two" } ] }
                    ]}
                ]},
                { "type": "paragraph",
                  "content": [ { "type": "text", "text": "Expected: it works." } ] }
              ]
            }
          }
        }
        """
        JiraStubURLProtocol.responder = { request in
            Self.makeResponse(status: 200, bodyString: body, url: request.url!)
        }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "PROJ-300")

        XCTAssertEqual(
            ticket?.description,
            "Repro\n\nStep one\n\nStep two\n\nExpected: it works."
        )
        XCTAssertNil(ticket?.priority, "missing priority should decode as nil")
    }

    // MARK: - 401

    func testUnauthorizedThrows() async {
        JiraStubURLProtocol.responder = { request in
            Self.makeResponse(status: 401, bodyString: "no", url: request.url!)
        }
        let client = makeClient(session: makeSession())
        do {
            _ = try await client.fetchTicket(key: "PROJ-1")
            XCTFail("Expected JiraError.unauthorized")
        } catch JiraClient.JiraError.unauthorized {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - 404 maps to nil-on-throw → handled by orchestrator

    func testNotFoundThrowsTicketNotFound() async {
        JiraStubURLProtocol.responder = { request in
            Self.makeResponse(status: 404, bodyString: "missing", url: request.url!)
        }
        let client = makeClient(session: makeSession())
        do {
            _ = try await client.fetchTicket(key: "PROJ-1")
            XCTFail("Expected JiraError.ticketNotFound")
        } catch JiraClient.JiraError.ticketNotFound {
            // expected — orchestrator maps this to "no Jira context"
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Other non-2xx

    func testServerErrorThrowsHttpWithBody() async {
        JiraStubURLProtocol.responder = { request in
            Self.makeResponse(status: 503, bodyString: "down", url: request.url!)
        }
        let client = makeClient(session: makeSession())
        do {
            _ = try await client.fetchTicket(key: "PROJ-1")
            XCTFail("Expected JiraError.http")
        } catch JiraClient.JiraError.http(let status, let body) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(body, "down")
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Not configured

    func testNotConfiguredWhenBaseURLMissing() async {
        let client = JiraClient(
            session: makeSession(),
            baseURLProvider: { nil },
            emailProvider: { "dev@example.com" },
            tokenProvider: { "tok" }
        )
        do {
            _ = try await client.fetchTicket(key: "PROJ-1")
            XCTFail("Expected JiraError.notConfigured")
        } catch JiraClient.JiraError.notConfigured {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    func testNotConfiguredWhenEmailMissing() async {
        let client = JiraClient(
            session: makeSession(),
            baseURLProvider: { "https://acme.atlassian.net" },
            emailProvider: { "" },
            tokenProvider: { "tok" }
        )
        do {
            _ = try await client.fetchTicket(key: "PROJ-1")
            XCTFail("Expected JiraError.notConfigured")
        } catch JiraClient.JiraError.notConfigured {
            // expected
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Trailing slash on base URL

    func testTrailingSlashOnBaseURLIsStripped() async throws {
        let body = """
        { "key": "X-1", "fields": { "summary": "x", "status": { "name": "x" }, "issuetype": { "name": "x" } } }
        """
        var seenURL: URL?
        JiraStubURLProtocol.responder = { request in
            seenURL = request.url
            return Self.makeResponse(status: 200, bodyString: body, url: request.url!)
        }
        let client = JiraClient(
            session: makeSession(),
            baseURLProvider: { "https://acme.atlassian.net///" },
            emailProvider: { "a@b.c" },
            tokenProvider: { "t" }
        )
        _ = try await client.fetchTicket(key: "X-1")
        XCTAssertEqual(seenURL?.path, "/rest/api/3/issue/X-1")
    }

    // MARK: - Helpers

    private static func makeResponse(status: Int, bodyString: String, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(bodyString.utf8))
    }
}

// MARK: - URLProtocol stub (parallel to GitHubClientTests' StubURLProtocol).
// Kept in its own class so multiple test files can register protocols
// against different sessions without stomping on each other's responders.

final class JiraStubURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var responder: Responder?

    static func reset() { responder = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = JiraStubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "JiraStubURLProtocol", code: -1))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
