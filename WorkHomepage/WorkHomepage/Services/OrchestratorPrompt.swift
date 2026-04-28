//
//  OrchestratorPrompt.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//  Slice 11 — adds the subtask-with-parent prompt block. When the Jira
//  ticket carries an attached `parent`, we render a different shape that
//  surfaces "subtask of X" up top and includes the parent's description
//  underneath. No-parent and no-Jira shapes are unchanged from slice 10.
//  Slice 23 — PR-body block is now driven by the user-editable
//  `ReviewPromptStore` template, interpolated via `PromptInterpolator`.
//  The schema directive is auto-appended when absent from the rendered body.
//
//  Pulled out of `ReviewOrchestrator` so it can be unit-tested without
//  spinning up the orchestrator (which is `@MainActor` and owns SwiftData
//  state). Pure function: PR meta + optional Jira ticket → final prompt.
//
//  Format (Q6 from PRD):
//    - When Jira is wired up (no parent):
//        Jira: <KEY>
//        Title: <summary>
//        Type: <issueType>  Status: <status>  Priority: <priority or "Unset">
//        Description:
//        <plaintext description>
//
//        You are reviewing PR #<n> in <repo>, branch <branch>.
//        ...
//    - When Jira ticket is a subtask whose parent we also fetched:
//        Jira: <KEY> (subtask of <PARENT_KEY>)
//        Subtask title: <subtask summary>
//        Subtask description: <subtask plaintext or "(empty)">
//
//        Parent <PARENT_KEY> title: <parent summary>
//        Parent description: <parent plaintext>
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

    /// Substring that must be present in the rendered body. When a custom
    /// template omits it, `build` appends the canonical form automatically.
    static let schemaDirective = "Return JSON conformant to the provided schema"

    /// Full canonical schema directive appended when absent.
    private static let schemaDirectiveBlock = "\nReturn JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files."

    /// Hard cap on the size of the changed-files allowlist injected into
    /// the prompt. Generous (covers ~99% of PRs) but keeps prompt size
    /// bounded for the rare 5000-file mega-PR.
    private static let maxAllowlistEntries = 200

    /// Build the full prompt for one review run.
    ///
    /// `jira` is nil when no ticket key was extracted from the branch,
    /// the credentials weren't configured, the fetch failed, or the
    /// ticket wasn't found. In all of those cases the prompt opens with
    /// `Jira: null` so the model knows context is unavailable.
    ///
    /// Slice 23: the PR-body block is now sourced from `ReviewPromptStore`
    /// and interpolated with the four PR-level variables. The schema
    /// directive is auto-appended when absent.
    static func build(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        jira: JiraTicket?,
        changedFiles: [String]? = nil,
        store: ReviewPromptStore = ReviewPromptStore()
    ) -> String {
        let jiraBlock = renderJiraBlock(jira)
        let template = store.current()
        let vars: [String: String] = [
            "repo": repo,
            "prNumber": String(prNumber),
            "branch": branch,
            "sha": sha
        ]
        var body = PromptInterpolator.interpolate(template, vars: vars)
        if !body.contains(schemaDirective) {
            body += schemaDirectiveBlock
        }
        let allowlist = renderAllowlistBlock(changedFiles)
        return jiraBlock + "\n" + body + allowlist
    }

    /// Build the full prompt using an explicit template string (no store lookup).
    /// Used by `SettingsView` to render the live preview without persisting to
    /// `UserDefaults`.
    static func build(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        jira: JiraTicket?,
        template: String,
        changedFiles: [String]? = nil
    ) -> String {
        let jiraBlock = renderJiraBlock(jira)
        let vars: [String: String] = [
            "repo": repo,
            "prNumber": String(prNumber),
            "branch": branch,
            "sha": sha
        ]
        var body = PromptInterpolator.interpolate(template, vars: vars)
        if !body.contains(schemaDirective) {
            body += schemaDirectiveBlock
        }
        let allowlist = renderAllowlistBlock(changedFiles)
        return jiraBlock + "\n" + body + allowlist
    }

    /// Renders the changed-files allowlist as an instruction block appended
    /// after the user-editable template. Empty / nil input → empty string so
    /// the prompt is unchanged (useful when `gh pr view --json files` fails;
    /// we degrade to the previous behaviour rather than blocking the review).
    /// Above `maxAllowlistEntries`, only the first N are listed and the
    /// instruction notes truncation so the model knows the list isn't
    /// authoritative for very large PRs.
    static func renderAllowlistBlock(_ files: [String]?) -> String {
        guard let files, !files.isEmpty else { return "" }
        let dedup = Array(NSOrderedSet(array: files)) as? [String] ?? files
        let truncated = dedup.count > maxAllowlistEntries
        let visible = truncated ? Array(dedup.prefix(maxAllowlistEntries)) : dedup
        let bullets = visible.map { "  - \($0)" }.joined(separator: "\n")
        var block = "\n\nAllowed file paths (this PR's changed files):\n\(bullets)"
        if truncated {
            block += "\n  - (list truncated; this PR changes \(dedup.count) files — verify any path you cite by reading it)"
        }
        block += "\n\nEvery finding's `file` field MUST be copied verbatim from this list. Do not invent sibling paths, do not rename, do not normalise. If you want to flag something outside this list, omit the finding entirely."
        return block
    }

    // MARK: - Building blocks

    static func renderJiraBlock(_ jira: JiraTicket?) -> String {
        guard let jira else {
            return "Jira: null\n"
        }

        // Slice 11: subtask with attached parent gets a different shape so
        // the model sees both descriptions clearly delimited.
        if let parent = jira.parent {
            return renderSubtaskWithParentBlock(subtask: jira, parent: parent)
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

    /// Slice 11 — subtask block with attached parent. The shape was nailed
    /// down in PRD Q6c: lead with "subtask of PARENT", then the subtask's
    /// own (possibly empty) description, then a blank line, then the parent
    /// title + description. An empty subtask description renders as the
    /// literal "(empty)" rather than a blank value.
    private static func renderSubtaskWithParentBlock(
        subtask: JiraTicket,
        parent: JiraTicket
    ) -> String {
        let subtaskDesc = subtask.description.isEmpty ? "(empty)" : subtask.description
        var block = ""
        block += "Jira: \(subtask.key) (subtask of \(parent.key))\n"
        block += "Subtask title: \(subtask.summary)\n"
        block += "Subtask description: \(subtaskDesc)\n"
        block += "\n"
        block += "Parent \(parent.key) title: \(parent.summary)\n"
        block += "Parent description: \(parent.description)"
        // Trailing newline so the next section is visually separated even
        // when the parent description itself didn't end with one.
        if !block.hasSuffix("\n") { block += "\n" }
        return block
    }

}
