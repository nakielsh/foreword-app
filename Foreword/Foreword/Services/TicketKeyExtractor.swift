//
//  TicketKeyExtractor.swift
//  Foreword
//
//  Slice 10 — Jira basic.
//
//  Pure helper that pulls a Jira ticket key out of a PR head branch name.
//  The PRD (Q6) defines the convention as `<type>/<KEY>` where `<type>`
//  is one of feature/bugfix/hotfix/chore/task and `<KEY>` is an
//  uppercase project key plus dash plus number, e.g. `PROJ-123`.
//
//  Teams that name branches differently (`PROJ-123-add-thing`,
//  `jane/PROJ-123`) get a fallback: any `<KEY>-<n>` token in the branch is
//  accepted when `<KEY>` is one of the user's configured project key
//  prefixes (Settings → Behavior). Gating on the configured keys keeps
//  look-alikes such as `UTF-8` or `ISO-8601` from becoming ticket lookups.
//
//  Returns nil for branches that do not match (main, master, dependabot/*,
//  loose feature branches, …). The orchestrator treats nil as "no ticket"
//  and proceeds without Jira context.
//

import Foundation

enum TicketKeyExtractor {

    // ^(?:feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)
    // Anchored to the start so `PROJ-123` (no prefix) is rejected.
    private static let prefixedForm = try! NSRegularExpression(
        pattern: #"^(?:feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)"#
    )

    // A `<KEY>-<n>` token anywhere, not glued to surrounding letters/digits
    // (so `XPROJ-12` doesn't yield `PROJ-12`). `_`, `-`, `/` separate.
    private static let anywhereForm = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])([A-Z][A-Z0-9]*)-\d+(?![0-9])"#
    )

    /// Returns the Jira key (e.g. "PROJ-123") parsed from a branch name.
    ///
    /// First try: `(feature|bugfix|hotfix|chore|task)/<KEY>` where `<KEY>`
    /// is `[A-Z]+-\d+`. Case-sensitive on the project key (Jira keys are
    /// uppercase by convention). Only the segment immediately after the
    /// prefix is consulted.
    ///
    /// Fallback, only when `projectKeyPrefixes` is non-empty: the first
    /// `<KEY>-<n>` token anywhere in the branch whose `<KEY>` is one of the
    /// configured prefixes (compared case-insensitively).
    ///
    /// Returns nil when neither matches.
    static func extract(branchName: String, projectKeyPrefixes: [String] = []) -> String? {
        guard !branchName.isEmpty else { return nil }
        let range = NSRange(branchName.startIndex..<branchName.endIndex, in: branchName)

        if let match = prefixedForm.firstMatch(in: branchName, range: range),
           let keyRange = Range(match.range(at: 1), in: branchName) {
            return String(branchName[keyRange])
        }

        let configured = Set(projectKeyPrefixes.map { $0.uppercased() })
        guard !configured.isEmpty else { return nil }
        for match in anywhereForm.matches(in: branchName, range: range) {
            guard let keyRange = Range(match.range(at: 0), in: branchName),
                  let projectRange = Range(match.range(at: 1), in: branchName),
                  configured.contains(String(branchName[projectRange]))
            else { continue }
            return String(branchName[keyRange])
        }
        return nil
    }
}
