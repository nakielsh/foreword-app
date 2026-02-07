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
