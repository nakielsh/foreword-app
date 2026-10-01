//
//  PRBranchInfo.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  The Reviews tab's `PendingReviewPR` shape doesn't carry head branch / head
//  SHA — slice 02 didn't need them. The Review button does. Rather than touch
//  `ReviewsModels.swift` (which slice 02 owns), we fetch this on demand via a
//  small new sidecar method (`GitHubClient.fetchPRBranchInfo`).
//
//  Decode shape for `GET /repos/<owner>/<repo>/pulls/<number>` head subset.
//  Only fields we need are decoded; the response carries plenty more we ignore.
//

import struct Foundation.URL

/// Just enough of `GET /repos/{owner}/{repo}/pulls/{number}` to pull out the
/// head branch (`ref`) and SHA, which the Review button needs to ask
/// `WorktreeManager` to prepare a worktree.
struct PRBranchInfo: Decodable, Hashable {
    /// Branch name on the head fork (e.g. `feature/PROJ-123`).
    let headBranch: String
    /// Commit SHA at the tip of `headBranch` at the moment of fetch.
    let headSha: String

    /// Decoded directly off the REST envelope's `head.{ref,sha}`.
    /// We define a one-shot `init(from:)` so the call site stays
    /// `try decoder.decode(PRBranchInfo.self, from: data)`.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let head = try container.decode(Head.self, forKey: .head)
        self.headBranch = head.ref
        self.headSha = head.sha
    }

    /// Memberwise init for tests that build fixtures without going through
    /// JSON decoding.
    init(headBranch: String, headSha: String) {
        self.headBranch = headBranch
        self.headSha = headSha
    }

    enum CodingKeys: String, CodingKey {
        case head
    }

    private struct Head: Decodable {
        let ref: String
        let sha: String
    }
}
