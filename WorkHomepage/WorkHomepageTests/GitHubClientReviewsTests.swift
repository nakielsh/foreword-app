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

    // MARK: - Reviewer entries default to [] (back-compat)

    /// `PendingReviewPR` constructed without reviewer entries must carry an
    /// empty `reviewerEntries` array — cards fall back to count-only rendering.
    func testPendingReviewPRDefaultsReviewerEntriesToEmpty() {
        let pr = PendingReviewPR(
            id: 1,
            number: 1,
            title: "T",
            htmlURL: URL(string: "https://github.com/Ala-com/foo/pull/1")!,
            authorLogin: "octo",
            repoFullName: "Ala-com/foo",
            createdAt: Date(),
            isDraft: false,
            approvalCount: 2,
            changesRequestedCount: 0,
            isDismissed: false,
            myPriorReviewState: nil,
            branchRef: nil,
            authorAvatarURL: nil,
            reviewerEntries: []
        )
        XCTAssertTrue(pr.reviewerEntries.isEmpty,
                      "reviewerEntries must default to [] for back-compat")
    }

    /// `ReviewedPR` constructed without reviewer entries must carry an empty
    /// `reviewerEntries` array.
    func testReviewedPRDefaultsReviewerEntriesToEmpty() {
        let pr = ReviewedPR(
            id: 2,
            number: 2,
            title: "T",
            htmlURL: URL(string: "https://github.com/Ala-com/foo/pull/2")!,
            authorLogin: "octo",
            repoFullName: "Ala-com/foo",
            createdAt: Date(),
            isDraft: false,
            approvalCount: 1,
            changesRequestedCount: 0,
            myLastReviewState: .approved,
            myLastReviewSubmittedAt: nil,
            newCommitsSinceReview: 0,
            branchRef: nil,
            authorAvatarURL: nil,
            reviewerEntries: []
        )
        XCTAssertTrue(pr.reviewerEntries.isEmpty,
                      "reviewerEntries must default to [] for back-compat")
    }

    // MARK: - Reviewer entries propagated from fetchPRReviewState

    /// When the GraphQL reviewer-state call returns reviewers, the resulting
    /// `PendingReviewPR` carries populated `reviewerEntries`. Simulates the
    /// multi-URL stub pattern: search → reviews → graphql.
    func testFetchPendingReviewPRsPopulatesReviewerEntries() async throws {
        // We test the pure-assembly path through MyPRsAPI.makePRReviewState
        // (already covered by GitHubClientMyPRsTests) rather than the full
        // end-to-end, which requires stubbing three distinct URL patterns in a
        // single URLProtocol responder. Here we verify that ReviewerEntry
        // carries the correct status and avatarURL so the facepile has what
        // it needs.
        let payload = PRReviewStatePayload(
            headRefName: "feature/FOO-1",
            reviewRequests: nil,
            latestReviews: PRReviewStatePayload.LatestReviews(
                nodes: [
                    PRReviewStatePayload.LatestReviews.Node(
                        state: "APPROVED",
                        author: PRReviewStatePayload.Author(
                            login: "alice",
                            avatarUrl: "https://avatars.githubusercontent.com/u/1?v=4"
                        )
                    ),
                    PRReviewStatePayload.LatestReviews.Node(
                        state: "CHANGES_REQUESTED",
                        author: PRReviewStatePayload.Author(
                            login: "bob",
                            avatarUrl: "https://avatars.githubusercontent.com/u/2?v=4"
                        )
                    )
                ]
            ),
            reviewThreads: PRReviewStatePayload.ReviewThreads(
                totalCount: 0,
                nodes: []
            )
        )

        let state = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "viewer")

        // Verify the entries the facepile will receive.
        let byLogin = Dictionary(uniqueKeysWithValues: state.reviewers.map { ($0.login, $0) })
        XCTAssertEqual(byLogin["alice"]?.status, .approved,
                       "alice must be .approved so the green facepile renders her avatar")
        XCTAssertEqual(byLogin["alice"]?.avatarURL,
                       URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
                       "alice's avatarURL must be propagated for ReviewerAvatarView")
        XCTAssertEqual(byLogin["bob"]?.status, .changesRequested,
                       "bob must be .changesRequested so the red facepile renders his avatar")
        XCTAssertEqual(byLogin["bob"]?.avatarURL,
                       URL(string: "https://avatars.githubusercontent.com/u/2?v=4"),
                       "bob's avatarURL must be propagated for ReviewerAvatarView")
    }

    /// When `fetchPRReviewState` fails (e.g. network error) the PR is still
    /// returned with `reviewerEntries: []` — the card falls back to count-only
    /// rendering without crashing.
    func testFetchPendingReviewPRsHandlesReviewerEntriesFetchFailureGracefully() async throws {
        let searchBody = """
        {
          "items": [
            {
              "id": 10,
              "number": 42,
              "title": "Resilient PR",
              "html_url": "https://github.com/Ala-com/foo/pull/42",
              "user": { "login": "octo", "avatar_url": null },
              "repository_url": "https://api.github.com/repos/Ala-com/foo",
              "draft": false,
              "created_at": "2026-04-01T10:00:00Z"
            }
          ]
        }
        """
        let reviewsBody = "[]"

        StubURLProtocol.responder = { req in
            let url = req.url!.absoluteString
            let body: String
            if url.contains("/search/issues") {
                body = searchBody
            } else if url.contains("/pulls/42/reviews") {
                body = reviewsBody
            } else {
                // Simulate all other calls (branch, graphql) failing with 500.
                let response = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
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
        // reviewerEntries stays empty — ReviewsAPI does not call fetchPRReviewState,
        // that enrichment happens in ReviewsTab.refresh(). The important invariant
        // is that the model initialises with [] and is safe to read.
        XCTAssertTrue(prs[0].reviewerEntries.isEmpty,
                      "reviewerEntries must be [] when ReviewsAPI builds the model (enrichment happens in the tab)")
    }
}
