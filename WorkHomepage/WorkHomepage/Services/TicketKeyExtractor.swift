//
//  TicketKeyExtractor.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//
//  Pure helper that pulls a Jira ticket key out of a PR head branch name.
//  The PRD (Q6) defines the convention as `<type>/<KEY>` where `<type>`
//  is one of feature/bugfix/hotfix/chore/task and `<KEY>` is an
//  uppercase project key plus dash plus number, e.g. `PROJ-123`.
//
//  Returns nil for branches that do not match (main, master, dependabot/*,
//  loose feature branches, …). The orchestrator treats nil as "no ticket"
//  and proceeds without Jira context.
//

import Foundation

enum TicketKeyExtractor {

    /// Returns the Jira key (e.g. "PROJ-123") parsed from a branch name.
    ///
    /// Pattern: `(feature|bugfix|hotfix|chore|task)/<KEY>` where `<KEY>`
    /// is `[A-Z]+-\d+`. Case-sensitive on the project key (Jira keys are
    /// uppercase by convention). When two keys appear in the branch the
    /// first match wins — only the segment immediately after the prefix
    /// is consulted.
    ///
    /// Returns nil when the branch does not match.
    static func extract(branchName: String) -> String? {
        guard !branchName.isEmpty else { return nil }

        // ^(?:feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)
        // Anchored to the start so `PROJ-123` (no prefix) is rejected.
        let pattern = #"^(?:feature|bugfix|hotfix|chore|task)/([A-Z]+-\d+)"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }

        let range = NSRange(branchName.startIndex..<branchName.endIndex, in: branchName)
        guard let match = regex.firstMatch(in: branchName, options: [], range: range),
              match.numberOfRanges >= 2,
              let keyRange = Range(match.range(at: 1), in: branchName)
        else {
            return nil
        }

        return String(branchName[keyRange])
    }
}
