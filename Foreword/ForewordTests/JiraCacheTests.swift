//
//  JiraCacheTests.swift
//  ForewordTests
//
//  Slice 12 — Jira ticket cache. Verifies:
//
//   1. First fetch: cheap update + full fetch happen, cache is populated.
//   2. Repeat fetch with unchanged `updated`: only the cheap update fires.
//   3. `updated` changed upstream: cheap update + full fetch fire, cache is
//      refreshed.
//   4. Network error on the cheap update with a cached row present:
//      returns cached value, no throw.
//   5. Network error with no cached row: throws.
//   6. Subtask + parent both cached: parent's full fetch is NOT repeated
//      when its `updated` is unchanged.
//   7. "Clear Jira cache" semantics: deleting all rows actually empties the
//      store (covers the SettingsView Clear button's data path).
//
//  Stubs network with the `JiraStubURLProtocol` from slice 10. Cache uses
//  an in-memory `ModelContainer` so each test starts clean.
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class JiraCacheTests: XCTestCase {

    override func setUp() {
        super.setUp()
        JiraCacheStubURLProtocol.reset()
    }

    override func tearDown() {
        JiraCacheStubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Fixture builders

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [JiraCacheStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self, CachedJiraTicket.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeClient(session: URLSession, context: ModelContext?) -> JiraClient {
        JiraClient(
            session: session,
            baseURLProvider: { "https://acme.atlassian.net" },
            emailProvider: { "dev@example.com" },
            tokenProvider: { "secret-token" },
            context: context
        )
    }

    // MARK: - Recording stub

    /// Per-key responder bookkeeping how many times each `(key, fields)`
    /// combination was hit. Tests assert against `fullFetchCount(for:)` /
    /// `cheapFetchCount(for:)` to verify which network paths fired.
    private final class Recorder: @unchecked Sendable {
        private var fullBodies: [String: String] = [:]
        private var updatedValues: [String: String] = [:]
        private var fullCalls: [String: Int] = [:]
        private var cheapCalls: [String: Int] = [:]
        private var transportFailKeys: Set<String> = []
        private let lock = NSLock()

        func register(key: String, fullBody: String, updated: String) {
            lock.lock(); defer { lock.unlock() }
            fullBodies[key] = fullBody
            updatedValues[key] = updated
        }

        func setUpdated(key: String, updated: String) {
            lock.lock(); defer { lock.unlock() }
            updatedValues[key] = updated
        }

        func setFullBody(key: String, fullBody: String) {
            lock.lock(); defer { lock.unlock() }
            fullBodies[key] = fullBody
        }

        /// Make every cheap-update call for `key` fail at the URL-loading
        /// layer (mimics a connection drop). Full fetches for the same key
        /// remain stubbed and return as registered.
        func failCheapTransport(forKey key: String) {
            lock.lock(); defer { lock.unlock() }
            transportFailKeys.insert(key)
        }

        func clearTransportFailures() {
            lock.lock(); defer { lock.unlock() }
            transportFailKeys.removeAll()
        }

        func fullFetchCount(for key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return fullCalls[key] ?? 0
        }

        func cheapFetchCount(for key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return cheapCalls[key] ?? 0
        }

        /// Resolve a URLRequest to either a stubbed `(response, data)` or a
        /// transport-failure sentinel. Path is `/rest/api/3/issue/<key>`,
        /// the query carries `fields=...`. We branch on the projection so
        /// the cheap and full fetches are countable separately.
        func handle(request: URLRequest) -> StubResult {
            let url = request.url!
            let lastPath = url.path.split(separator: "/").last.map(String.init) ?? ""
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let fields = queryItems.first { $0.name == "fields" }?.value ?? ""

            lock.lock()
            let isCheap = (fields == "updated")
            if transportFailKeys.contains(lastPath) && isCheap {
                lock.unlock()
                return .transportFailure
            }
            if isCheap {
                cheapCalls[lastPath, default: 0] += 1
                let updated = updatedValues[lastPath]
                lock.unlock()
                guard let updated else {
                    return .response(JiraCacheTests.makeResponse(status: 404, bodyString: "no updated registered for \(lastPath)", url: url))
                }
                let body = """
                { "key": "\(lastPath)", "fields": { "updated": "\(updated)" } }
                """
                return .response(JiraCacheTests.makeResponse(status: 200, bodyString: body, url: url))
            }
            fullCalls[lastPath, default: 0] += 1
            let body = fullBodies[lastPath]
            lock.unlock()
            guard let body else {
                return .response(JiraCacheTests.makeResponse(status: 404, bodyString: "no full body registered for \(lastPath)", url: url))
            }
            return .response(JiraCacheTests.makeResponse(status: 200, bodyString: body, url: url))
        }

        enum StubResult {
            case response((HTTPURLResponse, Data))
            case transportFailure
        }
    }

    nonisolated private static func makeResponse(status: Int, bodyString: String, url: URL) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(bodyString.utf8))
    }

    /// Bind the recorder with a transport-failure-aware delivery path. When
    /// the recorder marks a request as a transport failure, the URLProtocol
    /// reports `didFailWithError` so the client sees a real `URLError`.
    /// (We can't reuse slice 10's `JiraStubURLProtocol` because its
    /// responder signature returns a non-optional `(HTTPURLResponse, Data)`
    /// pair with no path for delivering an `Error`.)
    private func installWithTransportFailures(_ recorder: Recorder) {
        JiraCacheStubURLProtocol.responder = { request in
            let result = recorder.handle(request: request)
            switch result {
            case .response(let pair):
                return .ok(pair)
            case .transportFailure:
                return .fail(URLError(.notConnectedToInternet))
            }
        }
    }

    // MARK: - Body helpers

    private static func ticketBody(
        key: String,
        summary: String = "Summary",
        descriptionText: String,
        status: String = "Open",
        issueType: String = "Story",
        priority: String? = "Medium",
        parentKey: String? = nil
    ) -> String {
        let escaped = descriptionText.replacingOccurrences(of: "\"", with: "\\\"")
        let descField: String
        if descriptionText.isEmpty {
            descField = "null"
        } else {
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
        let priorityField: String
        if let priority {
            priorityField = ", \"priority\": { \"name\": \"\(priority)\" }"
        } else {
            priorityField = ""
        }
        let parentField: String
        if let parentKey {
            parentField = ", \"parent\": { \"key\": \"\(parentKey)\" }"
        } else {
            parentField = ""
        }
        return """
        {
          "key": "\(key)",
          "fields": {
            "summary": "\(summary)",
            "status": { "name": "\(status)" },
            "issuetype": { "name": "\(issueType)" }\(priorityField)\(parentField),
            "description": \(descField)
          }
        }
        """
    }

    // MARK: - Tests

    /// First fetch hits both endpoints (cheap update + full fetch) and
    /// writes a row into the cache.
    func testFirstFetchPopulatesCache() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-1",
            fullBody: Self.ticketBody(key: "PROJ-1", descriptionText: String(repeating: "x", count: 200)),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        let ticket = try await client.fetchTicket(key: "PROJ-1")
        XCTAssertEqual(ticket?.key, "PROJ-1")
        XCTAssertEqual(recorder.cheapFetchCount(for: "PROJ-1"), 1)
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-1"), 1)

        let descriptor = FetchDescriptor<CachedJiraTicket>()
        let rows = try context.fetch(descriptor)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.key, "PROJ-1")
        XCTAssertEqual(rows.first?.updatedAt, "2026-05-08T10:00:00.000+0000")
    }

    /// Second fetch with unchanged `updated`: only the cheap call fires.
    func testRepeatFetchSkipsFullFetchWhenUpdatedUnchanged() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-2",
            fullBody: Self.ticketBody(key: "PROJ-2", descriptionText: String(repeating: "y", count: 200)),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        _ = try await client.fetchTicket(key: "PROJ-2")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-2"), 1)

        // Second fetch — cache hit expected.
        let ticket2 = try await client.fetchTicket(key: "PROJ-2")
        XCTAssertEqual(ticket2?.key, "PROJ-2")
        XCTAssertEqual(recorder.cheapFetchCount(for: "PROJ-2"), 2, "cheap update fires on every call")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-2"), 1, "full fetch must NOT be repeated when updated is unchanged")
    }

    /// `updated` bumped upstream: cheap call + full fetch fire, cache row
    /// is refreshed.
    func testUpdatedChangeRefreshesCache() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-3",
            fullBody: Self.ticketBody(key: "PROJ-3", summary: "Old", descriptionText: String(repeating: "z", count: 200)),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        _ = try await client.fetchTicket(key: "PROJ-3")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-3"), 1)

        // Bump upstream `updated` and rotate the body.
        recorder.setUpdated(key: "PROJ-3", updated: "2026-05-09T11:11:11.000+0000")
        recorder.setFullBody(
            key: "PROJ-3",
            fullBody: Self.ticketBody(key: "PROJ-3", summary: "New", descriptionText: String(repeating: "z", count: 200))
        )

        let ticket2 = try await client.fetchTicket(key: "PROJ-3")
        XCTAssertEqual(ticket2?.summary, "New")
        XCTAssertEqual(recorder.cheapFetchCount(for: "PROJ-3"), 2)
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-3"), 2, "stale cache row must trigger a full refetch")

        let rows = try context.fetch(FetchDescriptor<CachedJiraTicket>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.summary, "New")
        XCTAssertEqual(rows.first?.updatedAt, "2026-05-09T11:11:11.000+0000")
    }

    /// Network error on the cheap call with a cached row present: serve
    /// the cached row without throwing.
    func testTransportErrorOnCheapCallReturnsCached() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-4",
            fullBody: Self.ticketBody(key: "PROJ-4", summary: "Cached summary", descriptionText: String(repeating: "q", count: 200)),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        _ = try await client.fetchTicket(key: "PROJ-4")

        // Now make the cheap call fail at the transport layer.
        recorder.failCheapTransport(forKey: "PROJ-4")
        let ticket = try await client.fetchTicket(key: "PROJ-4")
        XCTAssertEqual(ticket?.summary, "Cached summary", "stale cached row should be returned on transport failure")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-4"), 1, "no extra full fetch on cheap-call transport failure")
    }

    /// Network error on the cheap call with NO cached row: must throw.
    func testTransportErrorWithoutCachedRowThrows() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-5",
            fullBody: Self.ticketBody(key: "PROJ-5", descriptionText: String(repeating: "p", count: 200)),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        recorder.failCheapTransport(forKey: "PROJ-5")
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        do {
            _ = try await client.fetchTicket(key: "PROJ-5")
            XCTFail("Expected throw on transport failure with empty cache")
        } catch {
            // Expected — any URLError is acceptable.
        }
    }

    /// Subtask with thin description triggers parent fetch. Both rows are
    /// cached. Re-fetching the subtask only re-triggers cheap calls — neither
    /// the subtask nor its parent should pay for a full fetch a second time.
    func testParentResolvedFromCacheOnRepeatedSubtaskFetch() async throws {
        let recorder = Recorder()
        recorder.register(
            key: "PROJ-S1",
            fullBody: Self.ticketBody(
                key: "PROJ-S1",
                summary: "Sub",
                descriptionText: "",
                issueType: "Sub-task",
                parentKey: "PROJ-P1"
            ),
            updated: "2026-05-08T10:00:00.000+0000"
        )
        recorder.register(
            key: "PROJ-P1",
            fullBody: Self.ticketBody(
                key: "PROJ-P1",
                summary: "Parent",
                descriptionText: "Parent has the real spec.",
                issueType: "Story"
            ),
            updated: "2026-05-08T09:00:00.000+0000"
        )
        installWithTransportFailures(recorder)

        let container = try makeContainer()
        let context = container.mainContext
        let client = makeClient(session: makeSession(), context: context)

        let first = try await client.fetchTicket(key: "PROJ-S1")
        XCTAssertEqual(first?.parent?.key, "PROJ-P1")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-S1"), 1)
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-P1"), 1)

        // Both cache rows present.
        let rows = try context.fetch(FetchDescriptor<CachedJiraTicket>())
        XCTAssertEqual(Set(rows.map(\.key)), ["PROJ-S1", "PROJ-P1"])

        // Second fetch: nothing upstream changed.
        let second = try await client.fetchTicket(key: "PROJ-S1")
        XCTAssertEqual(second?.parent?.key, "PROJ-P1")
        XCTAssertEqual(second?.parent?.summary, "Parent")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-S1"), 1, "subtask full fetch not repeated")
        XCTAssertEqual(recorder.fullFetchCount(for: "PROJ-P1"), 1, "parent full fetch not repeated")
        XCTAssertEqual(recorder.cheapFetchCount(for: "PROJ-S1"), 2)
        XCTAssertEqual(recorder.cheapFetchCount(for: "PROJ-P1"), 2)
    }

    /// "Clear Jira cache" — verifies the bulk delete path that
    /// `SettingsView.clearJiraCache()` uses. Insert two rows, delete all,
    /// confirm none remain.
    func testClearJiraCacheRemovesAllRows() async throws {
        let container = try makeContainer()
        let context = container.mainContext

        for key in ["A-1", "A-2"] {
            let row = CachedJiraTicket(
                key: key,
                summary: "S",
                descriptionText: "D",
                status: "Open",
                issueType: "Story",
                priority: nil,
                parentKey: nil,
                updated: "2026-01-01T00:00:00.000+0000"
            )
            context.insert(row)
        }
        try context.save()
        XCTAssertEqual(try context.fetch(FetchDescriptor<CachedJiraTicket>()).count, 2)

        // Mirror the SettingsView Clear handler.
        let rows = try context.fetch(FetchDescriptor<CachedJiraTicket>())
        for row in rows {
            context.delete(row)
        }
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<CachedJiraTicket>()).count, 0)
    }
}

// MARK: - Transport-failure-aware URLProtocol stub

/// Slice-12-specific stub. The slice-10 `JiraStubURLProtocol` only models
/// success-path responses (its responder signature returns a non-optional
/// `(HTTPURLResponse, Data)`). The cache tests need a third option:
/// "the request never reached an HTTP layer at all" — which is what a real
/// transport failure looks like to `URLSession.data(for:)`.
final class JiraCacheStubURLProtocol: URLProtocol {
    enum Result {
        case ok((HTTPURLResponse, Data))
        case fail(Error)
    }

    typealias Responder = (URLRequest) -> Result

    nonisolated(unsafe) static var responder: Responder?

    static func reset() { responder = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = JiraCacheStubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "JiraCacheStubURLProtocol", code: -1))
            return
        }
        switch responder(request) {
        case .ok(let pair):
            let (response, data) = pair
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
