//
//  GitHubClientMyPRsTests.swift
//  WorkHomepageTests
//
//  Slice 03 — covers:
//   - REST decode of `/search/issues?q=author:@me+is:pr+is:open`
//   - GraphQL decode of the `pullRequest` payload used by `fetchPRReviewState`
//   - Pure derivation of "awaiting you" vs "awaiting others" through
//     `MyPRsAPI.makePRReviewState(payload:currentUser:)`. The current user's
//     login is a parameter (not hardcoded) so the same fixture flips its
//     classification when we swap the viewer.
//

import XCTest
@testable import WorkHomepage

@MainActor
final class GitHubClientMyPRsTests: XCTestCase {

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

    // MARK: - REST authored PRs

    func testFetchAuthoredPRsDecodesItems() async throws {
        let body = """
        {
          "items": [
            {
              "id": 42,
              "number": 9,
              "title": "Wire deploy badges",
              "html_url": "https://github.com/Ala-com/foo/pull/9",
              "user": { "login": "hubert" },
              "repository_url": "https://api.github.com/repos/Ala-com/foo",
              "draft": true,
              "created_at": "2026-04-30T10:11:12Z"
            }
          ]
        }
        """
        StubURLProtocol.responder = { req in
            XCTAssertNotNil(req.url?.absoluteString.range(of: "author:@me"))
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
        let prs = try await api.fetchAuthoredPRs()
        XCTAssertEqual(prs.count, 1)
        let pr = prs[0]
        XCTAssertEqual(pr.id, 42)
        XCTAssertEqual(pr.number, 9)
        XCTAssertEqual(pr.title, "Wire deploy badges")
        XCTAssertTrue(pr.draft)
        XCTAssertEqual(pr.user.login, "hubert")
        XCTAssertEqual(pr.repoFullName, "Ala-com/foo")
    }

    func testFetchAuthoredPRsUnauthorizedClearsTokenAndThrows() async {
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
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "stale" },
            onUnauthorized: { clearCalled = true }
        )
        do {
            _ = try await api.fetchAuthoredPRs()
            XCTFail("expected unauthorized")
        } catch GitHubError.unauthorized {
            XCTAssertTrue(clearCalled)
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchAuthoredPRsMissingTokenThrowsBeforeRequest() async {
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { nil },
            onUnauthorized: {}
        )
        do {
            _ = try await api.fetchAuthoredPRs()
            XCTFail("expected missingToken")
        } catch GitHubError.missingToken {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: - GraphQL fetchPRReviewState

    func testFetchPRReviewStateDecodesAndDerivesEverything() async throws {
        // Two reviewers: alice approved, bob requested changes; carol-the-team
        // is a pending team-typed reviewer. dave was already reviewed
        // (COMMENTED) but is now in `reviewRequests` again — we expect the
        // builder to mark him `reRequested`.
        // Three review threads:
        //   thread-1: resolved, ignored from "awaiting" math.
        //   thread-2: unresolved, last commenter is `viewer` -> awaiting others.
        //   thread-3: unresolved, last commenter is `alice`  -> awaiting you.
        let body = """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "reviewRequests": {
                  "nodes": [
                    { "requestedReviewer": { "__typename": "User", "login": "dave" } },
                    { "requestedReviewer": { "__typename": "Team", "name": "frontend" } }
                  ]
                },
                "latestReviews": {
                  "nodes": [
                    { "state": "APPROVED",          "author": { "login": "alice" } },
                    { "state": "CHANGES_REQUESTED", "author": { "login": "bob"   } },
                    { "state": "COMMENTED",         "author": { "login": "dave"  } }
                  ]
                },
                "reviewThreads": {
                  "totalCount": 3,
                  "nodes": [
                    {
                      "isResolved": true,
                      "comments": {
                        "totalCount": 2,
                        "nodes": [{ "author": { "login": "alice" } }]
                      }
                    },
                    {
                      "isResolved": false,
                      "comments": {
                        "totalCount": 4,
                        "nodes": [{ "author": { "login": "viewer" } }]
                      }
                    },
                    {
                      "isResolved": false,
                      "comments": {
                        "totalCount": 1,
                        "nodes": [{ "author": { "login": "alice" } }]
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        """
        StubURLProtocol.responder = { req in
            XCTAssertEqual(req.url?.absoluteString, "https://api.github.com/graphql")
            XCTAssertEqual(req.httpMethod, "POST")
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
            repo: "Ala-com/foo",
            number: 7,
            currentUser: "viewer"
        )

        // Reviewer order: latestReviews insertion order (alice, bob, dave),
        // then any new requested reviewers (frontend team).
        XCTAssertEqual(state.reviewers.map(\.login), ["alice", "bob", "dave", "frontend"])

        // Statuses + re-requested.
        let byLogin = Dictionary(uniqueKeysWithValues: state.reviewers.map { ($0.login, $0) })
        XCTAssertEqual(byLogin["alice"]?.status, .approved)
        XCTAssertEqual(byLogin["alice"]?.reRequested, false)
        XCTAssertEqual(byLogin["bob"]?.status, .changesRequested)
        XCTAssertEqual(byLogin["dave"]?.status, .commented)
        XCTAssertEqual(byLogin["dave"]?.reRequested, true,
                       "dave reviewed AND was re-requested -> reRequested=true")
        XCTAssertEqual(byLogin["frontend"]?.status, .pending)

        XCTAssertEqual(state.totalThreads, 3)
        XCTAssertEqual(state.totalComments, 2 + 4 + 1)
        XCTAssertEqual(state.unresolved.awaitingYou, 1,
                       "thread-3's last commenter is alice (not viewer)")
        XCTAssertEqual(state.unresolved.awaitingOthers, 1,
                       "thread-2's last commenter is viewer")
    }

    func testFetchPRReviewStateInvalidRepoThrowsTransport() async {
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        do {
            _ = try await api.fetchPRReviewState(
                repo: "no-slash",
                number: 1,
                currentUser: "viewer"
            )
            XCTFail("expected transport")
        } catch GitHubError.transport {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchPRReviewStateMissingPullRequestThrowsDecoding() async {
        let body = """
        { "data": { "repository": null } }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }

        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        do {
            _ = try await api.fetchPRReviewState(repo: "a/b", number: 1, currentUser: "v")
            XCTFail("expected decoding error")
        } catch GitHubError.decoding {
            // expected
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchPRReviewStateGraphQLErrorsSurfaceAsHttp() async {
        let body = """
        {
          "data": null,
          "errors": [{ "message": "Could not resolve to a PullRequest" }]
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let api = MyPRsAPI(
            session: makeSession(),
            tokenProvider: { "tok" },
            onUnauthorized: {}
        )
        do {
            _ = try await api.fetchPRReviewState(repo: "a/b", number: 999, currentUser: "v")
            XCTFail("expected http error")
        } catch GitHubError.http(_, let message) {
            XCTAssertTrue(message.contains("Could not resolve"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: - Pure derivation: viewer flip changes classification

    /// Same fixture, two different `currentUser` values.  The thread whose last
    /// comment is from `viewer` should count as "awaiting others" when viewer
    /// is the user, but flip to "awaiting you" if we swap to a different user.
    func testAwaitingYouVsOthersDependsOnCurrentUserParameter() {
        let payload = PRReviewStatePayload(
            reviewRequests: nil,
            latestReviews: nil,
            reviewThreads: PRReviewStatePayload.ReviewThreads(
                totalCount: 2,
                nodes: [
                    PRReviewStatePayload.ReviewThreads.Thread(
                        isResolved: false,
                        comments: PRReviewStatePayload.ReviewThreads.ThreadComments(
                            totalCount: 1,
                            nodes: [
                                PRReviewStatePayload.ReviewThreads.ThreadComment(
                                    author: PRReviewStatePayload.Author(login: "viewer")
                                )
                            ]
                        )
                    ),
                    PRReviewStatePayload.ReviewThreads.Thread(
                        isResolved: false,
                        comments: PRReviewStatePayload.ReviewThreads.ThreadComments(
                            totalCount: 1,
                            nodes: [
                                PRReviewStatePayload.ReviewThreads.ThreadComment(
                                    author: PRReviewStatePayload.Author(login: "alice")
                                )
                            ]
                        )
                    )
                ]
            )
        )

        let asViewer = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "viewer")
        XCTAssertEqual(asViewer.unresolved.awaitingYou, 1,
                       "alice's thread is awaiting viewer")
        XCTAssertEqual(asViewer.unresolved.awaitingOthers, 1,
                       "viewer's own reply is awaiting alice")

        let asAlice = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "alice")
        XCTAssertEqual(asAlice.unresolved.awaitingYou, 1,
                       "viewer's thread is awaiting alice")
        XCTAssertEqual(asAlice.unresolved.awaitingOthers, 1,
                       "alice's own reply is awaiting viewer")
    }

    func testAwaitingClassificationIgnoresResolvedThreads() {
        let payload = PRReviewStatePayload(
            reviewRequests: nil,
            latestReviews: nil,
            reviewThreads: PRReviewStatePayload.ReviewThreads(
                totalCount: 1,
                nodes: [
                    PRReviewStatePayload.ReviewThreads.Thread(
                        isResolved: true,
                        comments: PRReviewStatePayload.ReviewThreads.ThreadComments(
                            totalCount: 5,
                            nodes: [
                                PRReviewStatePayload.ReviewThreads.ThreadComment(
                                    author: PRReviewStatePayload.Author(login: "alice")
                                )
                            ]
                        )
                    )
                ]
            )
        )
        let state = MyPRsAPI.makePRReviewState(payload: payload, currentUser: "viewer")
        XCTAssertEqual(state.unresolved.awaitingYou, 0)
        XCTAssertEqual(state.unresolved.awaitingOthers, 0)
        XCTAssertEqual(state.totalThreads, 1)
        XCTAssertEqual(state.totalComments, 5,
                       "totalComments still aggregates resolved threads")
    }
}
