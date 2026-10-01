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
              "title": "Wire reviewer badges",
              "html_url": "https://github.com/acme/foo/pull/9",
              "user": {
                "login": "octocat",
                "avatar_url": "https://avatars.githubusercontent.com/u/12345?v=4"
              },
              "repository_url": "https://api.github.com/repos/acme/foo",
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
        XCTAssertEqual(pr.title, "Wire reviewer badges")
        XCTAssertTrue(pr.draft)
        XCTAssertEqual(pr.user.login, "octocat")
        XCTAssertEqual(pr.user.avatarURL, URL(string: "https://avatars.githubusercontent.com/u/12345?v=4"))
        XCTAssertEqual(pr.repoFullName, "acme/foo")
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
                "headRefName": "feature/PROJ-42-widget",
                "reviewRequests": {
                  "nodes": [
                    {
                      "requestedReviewer": {
                        "__typename": "User",
                        "login": "dave",
                        "avatarUrl": "https://avatars.githubusercontent.com/u/99?v=4"
                      }
                    },
                    { "requestedReviewer": { "__typename": "Team", "name": "frontend" } }
                  ]
                },
                "latestReviews": {
                  "nodes": [
                    {
                      "state": "APPROVED",
                      "author": {
                        "login": "alice",
                        "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4"
                      }
                    },
                    {
                      "state": "CHANGES_REQUESTED",
                      "author": {
                        "login": "bob",
                        "avatarUrl": "https://avatars.githubusercontent.com/u/2?v=4"
                      }
                    },
                    {
                      "state": "COMMENTED",
                      "author": { "login": "dave" }
                    }
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
            repo: "acme/foo",
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

        // Avatar URLs from latestReviews.author.avatarUrl.
        XCTAssertEqual(byLogin["alice"]?.avatarURL,
                       URL(string: "https://avatars.githubusercontent.com/u/1?v=4"),
                       "alice's avatar from latestReviews fragment")
        XCTAssertEqual(byLogin["bob"]?.avatarURL,
                       URL(string: "https://avatars.githubusercontent.com/u/2?v=4"),
                       "bob's avatar from latestReviews fragment")
        // dave has no avatarUrl in latestReviews but has one in reviewRequests.
        XCTAssertEqual(byLogin["dave"]?.avatarURL,
                       URL(string: "https://avatars.githubusercontent.com/u/99?v=4"),
                       "dave's avatar filled from reviewRequests when latestReviews has none")
        // Teams never have an avatarURL.
        XCTAssertNil(byLogin["frontend"]?.avatarURL,
                     "Team reviewers have no avatar URL")

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

    func testFetchPRReviewStateMissingPullRequestThrowsGraphqlPartial() async {
        // No `pullRequest` and no `errors` array → typed `.graphqlPartial`
        // with the synthetic "Missing pullRequest" message. This used to
        // throw `.decoding`; the wave-1 fix split forbidden / notFound /
        // graphqlPartial out so the receiver can render a typed message
        // instead of "decode error".
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
            XCTFail("expected graphqlPartial error")
        } catch GitHubError.graphqlPartial(let errors) {
            XCTAssertEqual(errors.count, 1)
            XCTAssertTrue(errors[0].contains("Missing pullRequest"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    func testFetchPRReviewStateGraphQLErrorsSurfaceAsNotFound() async {
        // `data.repository = null` + an errors array containing "Could not
        // resolve" → typed `.notFound`. Wave-1 wired the GraphQL error
        // handler to inspect the error text and pick the most-specific
        // typed case; the test was written before that landed.
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
            XCTFail("expected notFound error")
        } catch GitHubError.notFound(let body) {
            XCTAssertTrue(body.contains("Could not resolve"))
        } catch {
            XCTFail("wrong error \(error)")
        }
    }

    // MARK: - Slice 22: avatar URL plumbing

    /// When `avatarUrl` is absent from both `latestReviews` and `reviewRequests`,
    /// `ReviewerEntry.avatarURL` must be nil — no crash, no forced unwrap.
    func testReviewerEntryAvatarURLIsNilWhenMissing() async throws {
        let body = """
        {
          "data": {
            "repository": {
              "pullRequest": {
                "headRefName": "fix/nothing",
                "reviewRequests": {
                  "nodes": [
                    { "requestedReviewer": { "__typename": "User", "login": "carol" } }
                  ]
                },
                "latestReviews": {
                  "nodes": [
                    { "state": "COMMENTED", "author": { "login": "carol" } }
                  ]
                },
                "reviewThreads": { "totalCount": 0, "nodes": [] }
              }
            }
          }
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let api = MyPRsAPI(session: makeSession(), tokenProvider: { "tok" }, onUnauthorized: {})
        let state = try await api.fetchPRReviewState(repo: "acme/bar", number: 5, currentUser: "viewer")
        let carol = state.reviewers.first(where: { $0.login == "carol" })
        XCTAssertNotNil(carol)
        XCTAssertNil(carol?.avatarURL,
                     "avatarURL must be nil when avatarUrl is absent from both fragments")
    }

    /// When an authored PR fixture lacks `avatar_url`, `AuthoredPR.User.avatarURL` is nil.
    func testAuthoredPRUserAvatarURLIsNilWhenMissing() async throws {
        let body = """
        {
          "items": [
            {
              "id": 7,
              "number": 3,
              "title": "No avatar here",
              "html_url": "https://github.com/acme/bar/pull/3",
              "user": { "login": "oldbot" },
              "repository_url": "https://api.github.com/repos/acme/bar",
              "draft": false,
              "created_at": "2025-01-01T00:00:00Z"
            }
          ]
        }
        """
        StubURLProtocol.responder = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, body.data(using: .utf8)!)
        }
        let api = MyPRsAPI(session: makeSession(), tokenProvider: { "tok" }, onUnauthorized: {})
        let prs = try await api.fetchAuthoredPRs()
        XCTAssertEqual(prs.count, 1)
        XCTAssertNil(prs[0].user.avatarURL,
                     "avatarURL must be nil when avatar_url is absent from the payload")
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
