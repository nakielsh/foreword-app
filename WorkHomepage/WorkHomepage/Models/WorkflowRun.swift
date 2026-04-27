//
//  WorkflowRun.swift
//  WorkHomepage
//
//  Slice 05: Codable shape for GitHub Actions workflow runs.
//

import struct Foundation.URL
import struct Foundation.Date

struct WorkflowRun: Codable, Hashable, Identifiable {
    let id: Int
    let name: String
    let status: String?
    let conclusion: String?
    // TODO(leftovers): Make `htmlURL` optional (`URL?`). An empty-string value
    // from the API currently breaks the entire `RunsResponse` decode. Cannot
    // flip in this pass without touching `Views/DeploysTab.swift` and
    // `Models/Deployment.swift` (both off-limits to this agent) — the view
    // passes `run.htmlURL` straight into `Deployment(htmlURL: URL, ...)`.
    let htmlURL: URL
    let createdAt: Date
    let headBranch: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case status
        case conclusion
        case htmlURL = "html_url"
        case createdAt = "created_at"
        case headBranch = "head_branch"
    }
}
