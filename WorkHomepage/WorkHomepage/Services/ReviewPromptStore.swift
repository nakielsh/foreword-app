//
//  ReviewPromptStore.swift
//  WorkHomepage
//
//  Slice 23 — Custom Review Prompt Template.
//
//  Wraps the `reviewPromptTemplate` UserDefaults key. The default template
//  reproduces the original hard-coded `OrchestratorPrompt.renderPRBody` text
//  byte-for-byte, with the four dynamic segments replaced by `{{repo}}`,
//  `{{prNumber}}`, `{{branch}}`, and `{{sha}}` placeholders.
//
//  Tests should inject their own `UserDefaults(suiteName:)` instance to avoid
//  polluting the real user defaults store.
//

import Foundation

final class ReviewPromptStore {

    // MARK: - Constants

    static let defaultsKey = "reviewPromptTemplate"

    /// The four placeholder names that `OrchestratorPrompt.build` supplies.
    static let knownVariableKeys: Set<String> = ["repo", "prNumber", "branch", "sha"]

    // The default template mirrors `OrchestratorPrompt.renderPRBody` exactly,
    // with the four dynamic values replaced by `{{…}}` tokens.
    // The `alignmentClause` in the original is Jira-context-aware; the template
    // exposes the with-Jira variant because `OrchestratorPrompt.build` will
    // select the right clause at render time and inject the final string as-is.
    // NOTE: The schema directive line is intentionally included here so that
    // `OrchestratorPrompt.build` can detect its presence. Users who remove it
    // from their custom template will get it auto-appended.
    static let defaultTemplate: String = """
        You are reviewing PR #{{prNumber}} in {{repo}}, branch {{branch}}.

        Use `gh pr view {{prNumber}} --repo {{repo}}` and `gh pr diff {{prNumber}} --repo {{repo}}` to fetch PR details and the diff. Use `git log`, `git blame`, and file reads in the current working directory to understand context. The current directory IS the PR head checked out at SHA {{sha}}.

        Review the changes for correctness, ticket alignment (verify the diff matches the Jira description above), and code quality.

        Return JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files.
        """

    // MARK: - Storage

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - API

    /// Returns the user-set template if one has been saved, otherwise the
    /// built-in `defaultTemplate`.
    func current() -> String {
        defaults.string(forKey: Self.defaultsKey) ?? Self.defaultTemplate
    }

    /// Persist a custom template. An empty or whitespace-only value is treated
    /// the same as no value — it resets to the default.
    func setCurrent(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            reset()
        } else {
            defaults.set(value, forKey: Self.defaultsKey)
        }
    }

    /// Remove the stored value, restoring the default template.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
