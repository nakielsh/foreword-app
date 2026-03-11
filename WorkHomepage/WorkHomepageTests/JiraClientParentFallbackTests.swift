//
//  JiraClientParentFallbackTests.swift
//  WorkHomepageTests
//
//  Slice 11. Verifies the subtask-parent fallback in `JiraClient.fetchTicket`:
//  thin subtasks pull in their parent (one level only), rich subtasks don't,
//  top-level tickets behave identically to slice 10. Reuses the
//  `JiraStubURLProtocol` from slice 10 — registered twice into the same
//  test session is fine, both targets resolve to the same nonisolated
//  responder.
//

import XCTest
@testable import WorkHomepage

final class JiraClientParentFallbackTests: XCTestCase {

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

    // MARK: - Fixtures

    /// Body for a subtask ticket. Pass `descriptionText` to control the
    /// flattened plaintext length; pass an empty string to simulate
    /// `description: null`.
    private static func subtaskBody(
        key: String,
        parentKey: String,
        descriptionText: String
    ) -> String {
        let descField: String
        if descriptionText.isEmpty {
            descField = "null"
        } else {
            // Single paragraph so the flattened plaintext length matches
            // descriptionText.count exactly (no \n\n separators).
            let escaped = descriptionText.replacingOccurrences(of: "\"", with: "\\\"")
            descField = """
            {
              "type": "doc", "version": 1, "content": [
                { "type": "paragraph", "content": [
                  { "type": "text", "text": "\(escaped)" }
                ]}
              ]
            }
            """
        }
        return """
        {
          "key": "\(key)",
          "fields": {
            "summary": "Subtask summary for \(key)",
            "status": { "name": "To Do" },
            "issuetype": { "name": "Sub-task" },
            "priority": { "name": "Medium" },
            "parent": { "key": "\(parentKey)" },
            "description": \(descField)
          }
        }
        """
    }

    /// Body for a parent / top-level ticket. `claimsParent` simulates the
    /// degenerate Jira state where the "parent" itself reports a parent of
    /// its own — used to verify we never recurse past one level.
    private static func parentBody(
        key: String,
        descriptionText: String,
        claimsParent: String? = nil
    ) -> String {
        let parentField: String
        if let claimsParent {
            parentField = ", \"parent\": { \"key\": \"\(claimsParent)\" }"
        } else {
            parentField = ""
        }
        let escaped = descriptionText.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {
          "key": "\(key)",
          "fields": {
            "summary": "Parent summary for \(key)",
            "status": { "name": "In Progress" },
            "issuetype": { "name": "Story" },
            "priority": { "name": "High" }\(parentField),
            "description": {
              "type": "doc", "version": 1, "content": [
                { "type": "paragraph", "content": [
                  { "type": "text", "text": "\(escaped)" }
                ]}
              ]
            }
          }
        }
        """
    }

    private static func makeResponse(status: Int, bodyString: String, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(bodyString.utf8))
    }

    /// Per-key responder. Tracks a call count per key so tests can assert
    /// "parent fetched" / "parent NOT fetched". Unknown keys produce a 404
    /// — surfaces as `JiraError.ticketNotFound` and fails the test loudly.
    private final class KeyedResponder: @unchecked Sendable {
        private var bodies: [String: String] = [:]
        private(set) var callCounts: [String: Int] = [:]
        private let lock = NSLock()

        func register(key: String, body: String) {
            lock.lock(); defer { lock.unlock() }
            bodies[key] = body
        }

        func responder(for request: URLRequest) -> (HTTPURLResponse, Data) {
            let url = request.url!
            // Path looks like `/rest/api/3/issue/<KEY>`.
            let lastComponent = url.path.split(separator: "/").last.map(String.init) ?? ""
            lock.lock()
            callCounts[lastComponent, default: 0] += 1
            let body = bodies[lastComponent]
            lock.unlock()
            if let body {
                return JiraClientParentFallbackTests.makeResponse(status: 200, bodyString: body, url: url)
            }
            return JiraClientParentFallbackTests.makeResponse(
                status: 404,
                bodyString: "no body registered for \(lastComponent)",
                url: url
            )
        }
    }

    // MARK: - Empty subtask description → parent fetched

    func testEmptySubtaskDescriptionTriggersParentFetch() async throws {
        let keyed = KeyedResponder()
        keyed.register(
            key: "JWT-200",
            body: Self.subtaskBody(key: "JWT-200", parentKey: "JWT-100", descriptionText: "")
        )
        keyed.register(
            key: "JWT-100",
            body: Self.parentBody(key: "JWT-100", descriptionText: "Real spec lives here on the parent.")
        )
        JiraStubURLProtocol.responder = { keyed.responder(for: $0) }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "JWT-200")

        XCTAssertNotNil(ticket)
        XCTAssertEqual(ticket?.key, "JWT-200")
        XCTAssertEqual(ticket?.description, "")
        XCTAssertNotNil(ticket?.parent, "parent should be attached when subtask description is empty")
        XCTAssertEqual(ticket?.parent?.key, "JWT-100")
        XCTAssertEqual(ticket?.parent?.description, "Real spec lives here on the parent.")
        XCTAssertEqual(keyed.callCounts["JWT-200"], 1)
        XCTAssertEqual(keyed.callCounts["JWT-100"], 1, "parent should be fetched exactly once")
    }

    // MARK: - Short subtask description → parent fetched

    func testShortSubtaskDescriptionTriggersParentFetch() async throws {
        // 50 chars — comfortably below the ~100 char threshold.
        let shortDesc = String(repeating: "a", count: 50)
        XCTAssertLessThan(shortDesc.count, JiraClient.thinDescriptionThreshold)

        let keyed = KeyedResponder()
        keyed.register(
            key: "JWT-201",
            body: Self.subtaskBody(key: "JWT-201", parentKey: "JWT-101", descriptionText: shortDesc)
        )
        keyed.register(
            key: "JWT-101",
            body: Self.parentBody(key: "JWT-101", descriptionText: "Parent details.")
        )
        JiraStubURLProtocol.responder = { keyed.responder(for: $0) }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "JWT-201")

        XCTAssertEqual(ticket?.description, shortDesc)
        XCTAssertNotNil(ticket?.parent)
        XCTAssertEqual(ticket?.parent?.key, "JWT-101")
        XCTAssertEqual(keyed.callCounts["JWT-201"], 1)
        XCTAssertEqual(keyed.callCounts["JWT-101"], 1)
    }

    // MARK: - Rich subtask description → parent NOT fetched

    func testRichSubtaskDescriptionDoesNotTriggerParentFetch() async throws {
        // 200 chars — well above the threshold.
        let richDesc = String(repeating: "x", count: 200)
        XCTAssertGreaterThanOrEqual(richDesc.count, JiraClient.thinDescriptionThreshold)

        let keyed = KeyedResponder()
        keyed.register(
            key: "JWT-202",
            body: Self.subtaskBody(key: "JWT-202", parentKey: "JWT-102", descriptionText: richDesc)
        )
        // Intentionally do NOT register the parent — if `fetchTicket` tries
        // to fetch it, we'll see either a 404-driven throw or a non-zero
        // call count for JWT-102. Both fail the test.
        JiraStubURLProtocol.responder = { keyed.responder(for: $0) }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "JWT-202")

        XCTAssertEqual(ticket?.description, richDesc)
        XCTAssertNil(ticket?.parent, "rich subtask should NOT trigger a parent fetch")
        XCTAssertEqual(keyed.callCounts["JWT-202"], 1)
        XCTAssertNil(keyed.callCounts["JWT-102"], "parent endpoint should never be touched")
    }

    // MARK: - Top-level ticket → no extra fetch

    func testTopLevelTicketDoesNotTriggerExtraFetch() async throws {
        let keyed = KeyedResponder()
        keyed.register(
            key: "JWT-300",
            body: Self.parentBody(key: "JWT-300", descriptionText: "Top-level ticket body.")
        )
        JiraStubURLProtocol.responder = { keyed.responder(for: $0) }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "JWT-300")

        XCTAssertNotNil(ticket)
        XCTAssertNil(ticket?.parentKey, "top-level ticket should have no parentKey")
        XCTAssertNil(ticket?.parent, "top-level ticket should have no attached parent")
        XCTAssertEqual(keyed.callCounts["JWT-300"], 1, "exactly one fetch for a top-level ticket")
        XCTAssertEqual(keyed.callCounts.values.reduce(0, +), 1, "no other endpoints touched")
    }

    // MARK: - Grandparent is NEVER fetched

    func testGrandparentIsNeverFetched() async throws {
        // Synthetic Jira state: the parent itself claims a parent. We must
        // ignore that claim and stop after one hop.
        let keyed = KeyedResponder()
        keyed.register(
            key: "JWT-400",
            body: Self.subtaskBody(key: "JWT-400", parentKey: "JWT-401", descriptionText: "")
        )
        keyed.register(
            key: "JWT-401",
            body: Self.parentBody(
                key: "JWT-401",
                descriptionText: "Parent that lies about having its own parent.",
                claimsParent: "JWT-402"
            )
        )
        // JWT-402 deliberately NOT registered — any attempt to fetch it would
        // 404 (and a 404 on the grandparent would surface as a thrown error,
        // failing the test loudly).
        JiraStubURLProtocol.responder = { keyed.responder(for: $0) }

        let client = makeClient(session: makeSession())
        let ticket = try await client.fetchTicket(key: "JWT-400")

        XCTAssertNotNil(ticket?.parent)
        XCTAssertEqual(ticket?.parent?.key, "JWT-401")
        XCTAssertNil(ticket?.parent?.parent, "the parent's parent must always be nil")
        XCTAssertEqual(keyed.callCounts["JWT-400"], 1)
        XCTAssertEqual(keyed.callCounts["JWT-401"], 1)
        XCTAssertNil(keyed.callCounts["JWT-402"], "grandparent endpoint must NEVER be touched")
    }
}
