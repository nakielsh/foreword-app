//
//  WorkflowRunsDecodingTests.swift
//  WorkHomepageTests
//
//  Slice 05: stub URLProtocol with synthetic GitHub Actions API responses
//  and verify `WorkflowsAPI.fetchWorkflowRuns` decodes them and walks paging
//  the way index.html does.
//

import XCTest
@testable import WorkHomepage

@MainActor
final class WorkflowRunsDecodingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WorkflowsStubURLProtocol.reset()
    }

    override func tearDown() {
        WorkflowsStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WorkflowsStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testDecodesWorkflowsListAndRunsAndMapsFields() async throws {
        let workflowsBody = """
        {
          "workflows": [
            { "id": 1, "name": "Other workflow" },
            { "id": 42, "name": "Deploy to EKS from ECR" }
          ]
        }
        """
        let runsBody = """
        {
          "workflow_runs": [
            {
              "id": 1001,
              "name": "[dev] Deploy v1.21.1-feature-xyz-snapshot",
              "status": "completed",
              "conclusion": "success",
              "html_url": "https://github.com/Ala-com/backend-account/actions/runs/1001",
              "created_at": "2025-12-15T10:00:00Z",
              "head_branch": "feature/xyz"
            },
            {
              "id": 1002,
              "name": "[prod] Deploy v1.21.0",
              "status": "completed",
              "conclusion": "success",
              "html_url": "https://github.com/Ala-com/backend-account/actions/runs/1002",
              "created_at": "2025-12-14T09:00:00Z",
              "head_branch": "main"
            }
          ]
        }
        """
        WorkflowsStubURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/actions/workflows?") || url.hasSuffix("/actions/workflows") {
                return Self.respond(url: request.url!, body: workflowsBody)
            }
            if url.contains("/actions/workflows/42/runs") {
                return Self.respond(url: request.url!, body: runsBody)
            }
            return Self.respond(url: request.url!, status: 404, body: "{}")
        }

        let runs = try await WorkflowsAPI.fetchWorkflowRuns(
            org: "Ala-com",
            repo: "backend-account",
            workflow: "Deploy to EKS from ECR",
            perPage: 100,
            pages: 2,
            session: makeSession(),
            tokenProvider: { "fake-token" },
            onUnauthorized: {}
        )

        XCTAssertEqual(runs.count, 2)

        let first = runs[0]
        XCTAssertEqual(first.id, 1001)
        XCTAssertEqual(first.name, "[dev] Deploy v1.21.1-feature-xyz-snapshot")
        XCTAssertEqual(first.status, "completed")
        XCTAssertEqual(first.conclusion, "success")
        XCTAssertEqual(
            first.htmlURL,
            URL(string: "https://github.com/Ala-com/backend-account/actions/runs/1001")
        )
        XCTAssertEqual(first.headBranch, "feature/xyz")

        let second = runs[1]
        XCTAssertEqual(second.id, 1002)
        XCTAssertEqual(second.headBranch, "main")
    }

    func testReturnsEmptyWhenWorkflowNotFoundByName() async throws {
        let workflowsBody = """
        {
          "workflows": [
            { "id": 1, "name": "Some other workflow" }
          ]
        }
        """
        WorkflowsStubURLProtocol.responder = { request in
            return Self.respond(url: request.url!, body: workflowsBody)
        }

        let runs = try await WorkflowsAPI.fetchWorkflowRuns(
            org: "Ala-com",
            repo: "backend-x",
            workflow: "Deploy to EKS from ECR",
            session: makeSession(),
            tokenProvider: { "fake-token" },
            onUnauthorized: {}
        )

        XCTAssertEqual(runs, [])
    }

    func testStopsPagingWhenPageReturnsLessThanPerPage() async throws {
        // Workflows lookup → id 7
        // Runs page 1 returns 2 runs (less than perPage=100) so we stop after page 1.
        let workflowsBody = """
        { "workflows": [ { "id": 7, "name": "Deploy to EKS from ECR" } ] }
        """
        let runsBody = """
        {
          "workflow_runs": [
            {
              "id": 1,
              "name": "[dev] Deploy v0.1.0",
              "status": "completed",
              "conclusion": "success",
              "html_url": "https://example.com/runs/1",
              "created_at": "2025-12-15T10:00:00Z",
              "head_branch": "main"
            },
            {
              "id": 2,
              "name": "[prod] Deploy v0.1.0",
              "status": "completed",
              "conclusion": "success",
              "html_url": "https://example.com/runs/2",
              "created_at": "2025-12-14T10:00:00Z",
              "head_branch": "main"
            }
          ]
        }
        """

        var page1Calls = 0
        var page2Calls = 0
        WorkflowsStubURLProtocol.responder = { request in
            let url = request.url?.absoluteString ?? ""
            if url.contains("/actions/workflows?") || url.hasSuffix("/actions/workflows") {
                return Self.respond(url: request.url!, body: workflowsBody)
            }
            if url.contains("page=1") {
                page1Calls += 1
                return Self.respond(url: request.url!, body: runsBody)
            }
            if url.contains("page=2") {
                page2Calls += 1
                return Self.respond(url: request.url!, body: """
                { "workflow_runs": [] }
                """)
            }
            return Self.respond(url: request.url!, status: 404, body: "{}")
        }

        let runs = try await WorkflowsAPI.fetchWorkflowRuns(
            org: "Ala-com",
            repo: "backend-x",
            workflow: "Deploy to EKS from ECR",
            perPage: 100,
            pages: 2,
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(page1Calls, 1)
        XCTAssertEqual(page2Calls, 0, "Should stop paging when page returned < perPage")
    }

    func testUnauthorizedFiresCallbackAndThrows() async {
        WorkflowsStubURLProtocol.responder = { request in
            return Self.respond(url: request.url!, status: 401, body: "nope")
        }

        var clearCalled = false
        do {
            _ = try await WorkflowsAPI.fetchWorkflowRuns(
                org: "Ala-com",
                repo: "backend-x",
                workflow: "Deploy to EKS from ECR",
                session: makeSession(),
                tokenProvider: { "stale" },
                onUnauthorized: { clearCalled = true }
            )
            XCTFail("Expected unauthorized")
        } catch GitHubError.unauthorized {
            XCTAssertTrue(clearCalled)
        } catch {
            XCTFail("Wrong error: \(error)")
        }
    }

    // MARK: - Helpers

    private static func respond(url: URL, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }
}

// MARK: - URLProtocol stub (independent of GitHubClientTests.StubURLProtocol)

final class WorkflowsStubURLProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var responder: Responder?

    static func reset() { responder = nil }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = WorkflowsStubURLProtocol.responder else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "WorkflowsStubURLProtocol", code: -1))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
