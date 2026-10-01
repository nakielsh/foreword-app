//
//  PullRequest.swift
//  WorkHomepage
//
//  Slice 01: minimal Codable shape for GitHub /search/issues PR results.
//

import struct Foundation.URL

struct PullRequest: Codable, Identifiable, Hashable {
    let id: Int
    let number: Int
    let title: String
    let htmlURL: URL
    let user: User
    let repositoryURL: URL

    struct User: Codable, Hashable {
        let login: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case htmlURL = "html_url"
        case user
        case repositoryURL = "repository_url"
    }

    /// Returns "org/repo" parsed from the tail of `repositoryURL`.
    /// GitHub returns repository_url like "https://api.github.com/repos/acme/foo".
    var repoFullName: String {
        let components = repositoryURL.pathComponents
        // pathComponents includes leading "/" then "repos" then "<org>" then "<repo>".
        guard components.count >= 4 else { return repositoryURL.lastPathComponent }
        let org = components[components.count - 2]
        let repo = components[components.count - 1]
        return "\(org)/\(repo)"
    }
}
