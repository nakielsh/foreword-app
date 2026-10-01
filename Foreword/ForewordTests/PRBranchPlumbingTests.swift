//
//  PRBranchPlumbingTests.swift
//  ForewordTests
//
//  Slice 26 fix — branchRef plumbing tests.
//
//  Covers three scenarios:
//  1. `PRBranchAPI.fetchPRBranchInfo` parses `head.ref` from a fixture JSON
//     correctly (REST round-trip via URLProtocol stub).
//  2. `MyPRsAPI.makePRReviewState` propagates `headRefName` into
//     `PRReviewState.branchRef` (pure-function path, no network).
//  3. `MyPRsAPI.fetchPRReviewState` end-to-end: `branchRef` on the returned
//     `PRReviewState` matches the `headRefName` in the GraphQL fixture.
//

import XCTest
@testable import Foreword

@MainActor
final class PRBranchPlumbingTests: XCTestCase {

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

    // MARK: - 1. PRBranchAPI parses head.ref from REST fixture

    func testFetchPRBranchInfoParsesHeadRefCorrectly() async throws {
        // Minimal REST fixture — only the `head` sub-object is needed.
        let body = """
        {
          "number": 42,
          "title": "Wire Jira badge",
          "head": {
            "ref": "feature/PROJ-1",
            "sha": "abc123def456abc123def456abc123def456abc123"
          }
        }
        """
        StubURLProtocol.responder = { req in
            XCTAssertTrue(
                req.url?.absoluteString.contains("/pulls/42") == true,
                "Expected /pulls/42 in URL, got \(req.url?.absoluteString ?? "nil")"
            )
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }

        let api = PRBranchAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let info = try await api.fetchPRBranchInfo(repo: "acme/foo", number: 42)
        XCTAssertEqual(info.headBranch, "feature/PROJ-1")
        XCTAssertEqual(info.headSha, "abc123def456abc123def456abc123def456abc123")
    }

    func testFetchPRBranchInfoNonJiraBranchParsesCleanly() async throws {
        let body = """
        {
          "head": {
            "ref": "main",
            "sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
          }
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }
        let api = PRBranchAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let info = try await api.fetchPRBranchInfo(repo: "acme/foo", number: 1)
        XCTAssertEqual(info.headBranch, "main")
    }

    // MARK: - 2. Pure: makePRReviewState propagates headRefName → branchRef

    func testMakePRReviewStatePropagatesBranchRef() {
        let payload = PRReviewStatePayload(
            headRefName: "feature/PROJ-1",
            reviewRequests: nil,
            latestReviews: nil,
            reviewThreads: nil
        )
        let state = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "viewer")
        XCTAssertEqual(state.branchRef, "feature/PROJ-1",
                       "branchRef must be populated from headRefName in the GraphQL payload")
    }

    func testMakePRReviewStateNilHeadRefNameYieldsNilBranchRef() {
        let payload = PRReviewStatePayload(
            headRefName: nil,
            reviewRequests: nil,
            latestReviews: nil,
            reviewThreads: nil
        )
        let state = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "viewer")
        XCTAssertNil(state.branchRef,
                     "branchRef must be nil when headRefName is absent from the payload")
    }

    // MARK: - 3. fetchPRReviewState end-to-end: branchRef flows from GraphQL headRefName

    func testFetchPRReviewStateBranchRefFlowsFromHeadRefName() async throws {
        let body = """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "headRefName": "bugfix/AB-9",
                "reviewRequests": { "nodes": [] },
                "latestReviews": { "nodes": [] },
                "reviewThreads": { "totalCount": 0, "nodes": [] }
              }
            }
          }
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let state = try await api.fetchPRReviewState(
            repo: "acme/foo",
            number: 9,
            currentUser: "viewer"
        )
        XCTAssertEqual(state.branchRef, "bugfix/AB-9",
                       "branchRef must carry headRefName from the GraphQL response end-to-end")
    }

    func testFetchPRReviewStateBranchRefIsNilWhenHeadRefNameAbsent() async throws {
        let body = """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "reviewRequests": { "nodes": [] },
                "latestReviews": { "nodes": [] },
                "reviewThreads": { "totalCount": 0, "nodes": [] }
              }
            }
          }
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let state = try await api.fetchPRReviewState(
            repo: "acme/foo",
            number: 9,
            currentUser: "viewer"
        )
        XCTAssertNil(state.branchRef,
                     "branchRef must be nil when headRefName is absent from the GraphQL response")
    }
}
