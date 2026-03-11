//
//  OrchestratorPrompt.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//
//  Pulled out of `ReviewOrchestrator` so it can be unit-tested without
//  spinning up the orchestrator (which is `@MainActor` and owns SwiftData
//  state). Pure function: PR meta + optional Jira ticket → final prompt.
//
//  Format (Q6 from PRD):
//    - When Jira is wired up:
//        Jira: <KEY>
//        Title: <summary>
//        Type: <issueType>  Status: <status>  Priority: <priority or "Unset">
//        Description:
//        <plaintext description>
//
//        You are reviewing PR #<n> in <repo>, branch <branch>.
//        ...
//    - When no key on the branch / fetch failed:
//        Jira: null
//
//        You are reviewing PR #<n> in <repo>, branch <branch>.
//        ...
//

import Foundation

enum OrchestratorPrompt {

    /// Build the full prompt for one review run.
    ///
    /// `jira` is nil when no ticket key was extracted from the branch,
    /// the credentials weren't configured, the fetch failed, or the
    /// ticket wasn't found. In all of those cases the prompt opens with
    /// `Jira: null` so the model knows context is unavailable.
    static func build(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        jira: JiraTicket?
    ) -> String {
        let jiraBlock = renderJiraBlock(jira)
        let body = renderPRBody(repo: repo, prNumber: prNumber, branch: branch, sha: sha, hasJira: jira != nil)
        return jiraBlock + "\n" + body
    }

    // MARK: - Building blocks

    static func renderJiraBlock(_ jira: JiraTicket?) -> String {
        guard let jira else {
            return "Jira: null\n"
        }

        let priority = jira.priority?.isEmpty == false ? jira.priority! : "Unset"
        var block = ""
        block += "Jira: \(jira.key)\n"
        block += "Title: \(jira.summary)\n"
        block += "Type: \(jira.issueType)  Status: \(jira.status)  Priority: \(priority)\n"
        block += "Description:\n"
        block += jira.description
        // Trailing newline so the next section is visually separated even
        // when the description itself didn't end with one.
        if !block.hasSuffix("\n") { block += "\n" }
        return block
    }

    private static func renderPRBody(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        hasJira: Bool
    ) -> String {
        let alignmentClause = hasJira
            ? "ticket alignment (verify the diff matches the Jira description above)"
            : "ticket alignment (no Jira context provided this run)"

        return """
        You are reviewing PR #\(prNumber) in \(repo), branch \(branch).

        Use `gh pr view \(prNumber) --repo \(repo)` and `gh pr diff \(prNumber) --repo \(repo)` to fetch PR details and the diff. Use `git log`, `git blame`, and file reads in the current working directory to understand context. The current directory IS the PR head checked out at SHA \(sha).

        Review the changes for correctness, \(alignmentClause), and code quality.

        Return JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files.
        """
    }
}
