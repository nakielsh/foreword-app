//
//  GitHubClient+Workflows.swift
//  WorkHomepage
//
//  Slice 05: Deployments tab support.
//  Adds workflow-runs fetch to GitHubClient. Because GitHubClient's
//  session/token/onUnauthorized fields are private, this extension drives
//  a parallel request path using the same defaults (Keychain token).
//  Tests for the wiring use the dedicated `WorkflowsRequestExecutor` helper
//  exposed below so a stubbed URLSession can be injected.
//

import Foundation

extension GitHubClient {
    /// Fetches workflow runs for a repo's named workflow.
    ///
    /// 1. GET `/repos/<org>/<repo>/actions/workflows` to find the workflow id by name.
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
        tokenProvider: () -> String? = { KeychainStore.get(key: "github.token") },
        onUnauthorized: () -> Void = { KeychainStore.delete(key: "github.token") }
    ) async throws -> [WorkflowRun] {
        guard let token = tokenProvider() else { throw GitHubError.missingToken }

        let workflowsURL = "https://api.github.com/repos/\(org)/\(repo)/actions/workflows"
        let workflowsList: WorkflowsListResponse = try await getJSON(
            urlString: workflowsURL,
            token: token,
            session: session,
            onUnauthorized: onUnauthorized
        )

        guard let target = workflowsList.workflows.first(where: { $0.name == workflow }) else {
            return []
        }

        var collected: [WorkflowRun] = []
        for page in 1...max(1, pages) {
            let runsURL = "https://api.github.com/repos/\(org)/\(repo)/actions/workflows/\(target.id)/runs?per_page=\(perPage)&status=success&page=\(page)"
            let runsResp: RunsResponse = try await getJSON(
                urlString: runsURL,
                token: token,
                session: session,
                onUnauthorized: onUnauthorized
            )
            collected.append(contentsOf: runsResp.workflowRuns)
            if runsResp.workflowRuns.count < perPage { break }
        }
        return collected
    }

    // MARK: - Internal helpers

    private static func getJSON<T: Decodable>(
        urlString: String,
        token: String,
        session: URLSession,
        onUnauthorized: () -> Void
    ) async throws -> T {
        guard let url = URL(string: urlString) else {
            throw GitHubError.transport("Invalid URL: \(urlString)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GitHubError.transport("Non-HTTP response")
        }

        if http.statusCode == 401 {
            onUnauthorized()
            throw GitHubError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError.http(status: http.statusCode, body: body)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw GitHubError.decoding(String(describing: error))
        }
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
