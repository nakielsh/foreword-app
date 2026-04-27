//
//  GitHubClient+Workflows.swift
//  WorkHomepage
//
//  Slice 05: Deployments tab support.
//  Adds workflow-runs fetch to GitHubClient. Because GitHubClient's
//  session/token/onUnauthorized fields are private, this extension drives
//  a parallel request path using the same defaults (Keychain token).
//  Tests for the wiring use the dedicated `WorkflowsAPI` helper exposed
//  below so a stubbed URLSession can be injected.
//
//  All HTTP plumbing (auth headers, retries, ETag, rate-limit, decode
//  errors) lives in `HTTPClient.swift`. The `/actions/workflows` lookup
//  now follows `Link: rel="next"` so repos with >30 workflows don't
//  silently miss the deploy workflow.
//

import struct Foundation.Data
import struct Foundation.URL
import struct Foundation.URLRequest
import class Foundation.URLSession
import class Foundation.URLResponse
import class Foundation.HTTPURLResponse
import class Foundation.JSONDecoder

extension GitHubClient {
    /// Fetches workflow runs for a repo's named workflow.
    ///
    /// 1. Page `/repos/<org>/<repo>/actions/workflows` (following
    ///    `Link: rel="next"`) to find the workflow id by name. Pre-fix this
    ///    only inspected page 1, which silently dropped the deploy workflow
    ///    on repos with >30 workflows.
    /// 2. GET `/repos/<org>/<repo>/actions/workflows/<id>/runs?per_page=<n>&page=<p>`
    ///    paged up to `pages` times. Mirrors index.html paging behaviour so prod
    ///    runs aren't buried by frequent dev runs.
    ///
    /// Throws `GitHubError` consistent with the rest of the client.
    func fetchWorkflowRuns(
        repo: String,
        workflow: String,
        perPage: Int = 100,
        pages: Int = 2
    ) async throws -> [WorkflowRun] {
        return try await WorkflowsAPI.fetchWorkflowRuns(
            org: DeploymentsConfig.org,
            repo: repo,
            workflow: workflow,
            perPage: perPage,
            pages: pages,
            session: .shared,
            tokenProvider: { KeychainStore.get(key: "github.token") },
            onUnauthorized: { KeychainStore.delete(key: "github.token") }
        )
    }
}

/// Stand-alone, injectable workflow-runs fetcher. Used directly by tests
/// (where a stubbed URLSession is needed) and indirectly by `GitHubClient`
/// via the extension above.
enum WorkflowsAPI {
    static func fetchWorkflowRuns(
        org: String,
        repo: String,
        workflow: String,
        perPage: Int = 100,
        pages: Int = 2,
        session: URLSession = .shared,
        tokenProvider: @escaping () -> String? = { KeychainStore.get(key: "github.token") },
        onUnauthorized: @escaping () -> Void = { KeychainStore.delete(key: "github.token") }
    ) async throws -> [WorkflowRun] {
        let http = HTTPClient(
            session: session,
            tokenProvider: tokenProvider,
            onUnauthorized: onUnauthorized
        )

        // Step 1: workflow id lookup. Page through Link: rel="next" so a
        // repo with >30 workflows doesn't silently drop our target.
        let workflowsURL = "https://api.github.com/repos/\(org)/\(repo)/actions/workflows?per_page=100"
        var workflows: [WorkflowMeta] = []
        var nextURL: String? = workflowsURL
        var pageCount = 0
        while let current = nextURL, pageCount < HTTPClient.maxPaginationPages {
            let (envelope, headers): (WorkflowsListResponse, [String: String]) =
                try await http.getDecodedWithHeaders(
                    WorkflowsListResponse.self,
                    urlString: current
                )
            workflows.append(contentsOf: envelope.workflows)
            // Short-circuit once we've found the target — no need to keep paging.
            if workflows.contains(where: { $0.name == workflow }) {
                nextURL = nil
            } else {
                nextURL = HTTPClient.parseNextLink(headers["Link"])
            }
            pageCount += 1
        }

        guard let target = workflows.first(where: { $0.name == workflow }) else {
            return []
        }

        var collected: [WorkflowRun] = []
        for page in 1...max(1, pages) {
            let runsURL = "https://api.github.com/repos/\(org)/\(repo)/actions/workflows/\(target.id)/runs?per_page=\(perPage)&status=success&page=\(page)"
            let runsResp = try await http.getDecoded(RunsResponse.self, urlString: runsURL)
            collected.append(contentsOf: runsResp.workflowRuns)
            if runsResp.workflowRuns.count < perPage { break }
        }
        return collected
    }

    // MARK: - Response shapes

    struct WorkflowsListResponse: Decodable {
        let workflows: [WorkflowMeta]
    }

    struct WorkflowMeta: Decodable {
        let id: Int
        let name: String
    }

    struct RunsResponse: Decodable {
        let workflowRuns: [WorkflowRun]
        enum CodingKeys: String, CodingKey {
            case workflowRuns = "workflow_runs"
        }
    }
}
