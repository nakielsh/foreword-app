//
//  GitHubClientReviewsTests.swift
//  WorkHomepageTests
//
//  Slice 02 — sidecar fetch happy paths via URLProtocol stub.
//
//  Reuses `StubURLProtocol` defined in `GitHubClientTests.swift`.
//

import XCTest
@testable import WorkHomepage

@MainActor
final class GitHubClientReviewsTests: XCTestCase {

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

    // MARK: - fetchPRReviews REST decode

    func testFetchPRReviewsDecodesItems() async throws {
        let body = """
        [
          {
            "user": { "login": "alice", "avatar_url": "https://example.test/a.png" },
            "state": "APPROVED",
            "submitted_at": "2026-04-01T10:00:00Z"
          },
          {
            "user": { "login": "bob", "avatar_url": null },
            "state": "CHANGES_REQUESTED",
            "submitted_at": "2026-04-02T11:00:00Z"
          }
        ]
        """
        StubURLProtocol.responder = { req in
            XCTAssertNotNil(req.url?.absoluteString.range(of: "/pulls/7/reviews"))
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }

        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let reviews = try await api.fetchPRReviews(repo: "Ala-com/foo", number: 7)
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(reviews[0].user?.login, "alice")
        XCTAssertEqual(reviews[0].state, "APPROVED")
        XCTAssertEqual(reviews[1].user?.login, "bob")
        XCTAssertEqual(reviews[1].state, "CHANGES_REQUESTED")
    }

    func testFetchPRReviewsUnauthorizedClearsTokenAndThrows() async {
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data("nope".utf8))
        }
        var clearCalled = false
        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { "stale" },
            onUnauthorized: { clearCalled = true }
        )
        do {
            _ = try await api.fetchPRReviews(repo: "Ala-com/foo", number: 7)
            XCTFail("expected unauthorized")
        } catch GitHubError.unauthorized {
            XCTAssertTrue(clearCalled)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchPRReviewsMissingTokenThrowsBeforeRequest() async {
        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { nil },
            onUnauthorized: {}
        )
        do {
            _ = try await api.fetchPRReviews(repo: "Ala-com/foo", number: 7)
            XCTFail("expected missingToken")
        } catch GitHubError.missingToken {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: - fetchPRCommits REST decode

    func testFetchPRCommitsDecodesItemsAndPicksCommitterDate() async throws {
        let body = """
        [
          {
            "commit": {
              "committer": { "date": "2026-04-03T10:00:00Z" },
              "author":    { "date": "2026-04-01T10:00:00Z" }
            }
          },
          {
            "commit": {
              "committer": null,
              "author": { "date": "2026-04-04T10:00:00Z" }
            }
          }
        ]
        """
        StubURLProtocol.responder = { req in
            XCTAssertNotNil(req.url?.absoluteString.range(of: "/pulls/9/commits"))
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }
        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let commits = try await api.fetchPRCommits(repo: "Ala-com/foo", number: 9)
        XCTAssertEqual(commits.count, 2)
        XCTAssertNotNil(commits[0].effectiveDate)
        XCTAssertEqual(commits[0].effectiveDate, ISO8601DateFormatter().date(from: "2026-04-03T10:00:00Z"))
        XCTAssertEqual(commits[1].effectiveDate, ISO8601DateFormatter().date(from: "2026-04-04T10:00:00Z"))
    }

    // MARK: - fetchPendingReviewPRs end-to-end

    func testFetchPendingReviewPRsEnrichesEachPR() async throws {
        // Search returns one PR. The reviews endpoint then returns:
        //   alice approved, bob changes-requested, viewer dismissed.
        // Expected derived: approvalCount=1, changesRequestedCount=1,
        // isDismissed=true, myPriorReviewState=.dismissed.
        let searchBody = """
        {
          "items": [
            {
              "id": 1,
              "number": 7,
              "title": "Wire reviews",
              "html_url": "https://github.com/Ala-com/foo/pull/7",
              "user": { "login": "octo" },
              "repository_url": "https://api.github.com/repos/Ala-com/foo",
              "draft": false,
              "created_at": "2026-04-01T10:00:00Z"
            }
          ]
        }
        """
        let reviewsBody = """
        [
          {
            "user": { "login": "alice", "avatar_url": null },
            "state": "APPROVED",
            "submitted_at": "2026-04-01T10:00:00Z"
          },
          {
            "user": { "login": "bob", "avatar_url": null },
            "state": "CHANGES_REQUESTED",
            "submitted_at": "2026-04-02T10:00:00Z"
          },
          {
            "user": { "login": "viewer", "avatar_url": null },
            "state": "DISMISSED",
            "submitted_at": "2026-04-03T10:00:00Z"
          }
        ]
        """

        StubURLProtocol.responder = { req in
            let url = req.url!.absoluteString
            let body: String
            if url.contains("/search/issues") {
                body = searchBody
            } else if url.contains("/pulls/7/reviews") {
                body = reviewsBody
            } else {
                XCTFail("unexpected URL \(url)")
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }

        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let prs = try await api.fetchPendingReviewPRs(currentUser: "viewer")
        XCTAssertEqual(prs.count, 1)
        let pr = prs[0]
        XCTAssertEqual(pr.id, 1)
        XCTAssertEqual(pr.number, 7)
        XCTAssertEqual(pr.repoFullName, "Ala-com/foo")
        XCTAssertEqual(pr.approvalCount, 1)
        XCTAssertEqual(pr.changesRequestedCount, 1)
        XCTAssertTrue(pr.isDismissed)
        XCTAssertEqual(pr.myPriorReviewState, .dismissed)
        XCTAssertFalse(pr.isDraft)
    }

    // MARK: - fetchReviewedByMePRs end-to-end

    func testFetchReviewedByMePRsDerivesNewCommitsAndState() async throws {
        // viewer approved at 2026-04-01. Two commits: one before, one after.
        let searchBody = """
        {
          "items": [
            {
              "id": 2,
              "number": 9,
              "title": "Refactor",
              "html_url": "https://github.com/Ala-com/foo/pull/9",
              "user": { "login": "octo" },
              "repository_url": "https://api.github.com/repos/Ala-com/foo",
              "draft": false,
              "created_at": "2026-03-30T10:00:00Z"
            }
          ]
        }
        """
        let reviewsBody = """
        [
          {
            "user": { "login": "viewer", "avatar_url": null },
            "state": "APPROVED",
            "submitted_at": "2026-04-01T12:00:00Z"
          }
        ]
        """
        let commitsBody = """
        [
          { "commit": { "committer": { "date": "2026-03-31T10:00:00Z" }, "author": null } },
          { "commit": { "committer": { "date": "2026-04-02T10:00:00Z" }, "author": null } }
        ]
        """
        StubURLProtocol.responder = { req in
            let url = req.url!.absoluteString
            let body: String
            if url.contains("/search/issues") {
                body = searchBody
            } else if url.contains("/pulls/9/reviews") {
                body = reviewsBody
            } else if url.contains("/pulls/9/commits") {
                body = commitsBody
            } else {
                XCTFail("unexpected URL \(url)")
                body = "{}"
            }
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, body.data(using: .utf8)!)
        }

        let api = ReviewsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        let prs = try await api.fetchReviewedByMePRs(currentUser: "viewer")
        XCTAssertEqual(prs.count, 1)
        let pr = prs[0]
        XCTAssertEqual(pr.id, 2)
        XCTAssertEqual(pr.myLastReviewState, .approved)
        XCTAssertNotNil(pr.myLastReviewSubmittedAt)
        XCTAssertEqual(pr.newCommitsSinceReview, 1)
    }

    // MARK: - REST decode of search payload tolerates missing draft

    func testReviewsSearchPRDecodesWithMissingDraft() throws {
        let body = """
        {
          "items": [
            {
              "id": 3,
              "number": 11,
              "title": "no draft field",
              "html_url": "https://github.com/Ala-com/foo/pull/11",
              "user": { "login": "octo" },
              "repository_url": "https://api.github.com/repos/Ala-com/foo",
              "created_at": "2026-04-01T10:00:00Z"
            }
          ]
        }
        """.data(using: .utf8)!
        struct Env: Decodable { let items: [ReviewsSearchPR] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let env = try decoder.decode(Env.self, from: body)
        XCTAssertEqual(env.items.count, 1)
        XCTAssertNil(env.items[0].draft)
    }
}
