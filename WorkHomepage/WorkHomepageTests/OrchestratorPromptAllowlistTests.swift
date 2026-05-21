//
//  OrchestratorPromptAllowlistTests.swift
//  WorkHomepageTests
//
//  Covers the changed-files allowlist block appended by
//  `OrchestratorPrompt.renderAllowlistBlock` and threaded through
//  `OrchestratorPrompt.build`. The block anchors the model to the PR's
//  real paths so it doesn't invent plausible siblings.
//

import XCTest
@testable import WorkHomepage

final class OrchestratorPromptAllowlistTests: XCTestCase {

    func testRenderAllowlistReturnsEmptyForNilOrEmpty() {
        assertThat(OrchestratorPrompt.renderAllowlistBlock(nil)).isEqualTo("")
        assertThat(OrchestratorPrompt.renderAllowlistBlock([])).isEqualTo("")
    }

    func testRenderAllowlistBulletsAndInstruction() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock([
            "src/A.kt",
            "src/B.kt"
        ])
        assertThat(rendered).contains("Allowed file paths")
        assertThat(rendered).contains("  - src/A.kt")
        assertThat(rendered).contains("  - src/B.kt")
        assertThat(rendered).contains("copied verbatim from this list")
        XCTAssertFalse(rendered.contains("list truncated"))
    }

    func testRenderAllowlistDedupesPaths() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock([
            "src/A.kt",
            "src/A.kt",
            "src/B.kt"
        ])
        let occurrencesOfA = rendered.components(separatedBy: "  - src/A.kt").count - 1
        assertThat(occurrencesOfA).isEqualTo(1)
    }

    func testRenderAllowlistTruncatesAboveCap() {
        let many = (0..<300).map { "f\($0).kt" }
        let rendered = OrchestratorPrompt.renderAllowlistBlock(many)
        assertThat(rendered).contains("list truncated")
        assertThat(rendered).contains("touches 300 files")
        // First and 200th present, 201st absent.
        assertThat(rendered).contains("  - f0.kt")
        assertThat(rendered).contains("  - f199.kt")
        XCTAssertFalse(rendered.contains("  - f200.kt"))
    }

    func testRenderAllowlistMentionsAddedFilesAreIncluded() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock(["src/New.kt"])
        // The "added files appear here too" note is load-bearing — the model
        // was previously claiming new files were missing from the list.
        assertThat(rendered).contains("Added")
        assertThat(rendered).contains("`--- /dev/null`")
    }

    func testRenderAllowlistDirectsAgentToSkill() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock(["src/A.kt"])
        // The how-to (three-dot diff, forbidden commands, base-branch
        // discovery, filesystem-≠-membership) was moved into the
        // `reviewing-pr-final-state` skill. The allowlist block must
        // explicitly point the agent at the skill so it doesn't fall
        // back to its own ideas about how to scope a PR diff.
        assertThat(rendered).contains("reviewing-pr-final-state")
        assertThat(rendered).contains("skill")
        // Quick guardrails still mentioned by name so the agent has a
        // tripwire even if it skips the skill load.
        assertThat(rendered).contains("git show")
        assertThat(rendered).contains("per-commit")
        assertThat(rendered).contains("worktree filesystem existence")
    }

    func testBuildLeavesAllowlistBlockFreeOfTemplatePlaceholders() {
        let prompt = OrchestratorPrompt.build(
            repo: "Foo/Bar",
            prNumber: 42,
            branch: "feature/x",
            sha: "abc",
            jira: nil,
            changedFiles: ["src/Real.kt"]
        )
        // The allowlist block no longer carries `{{repo}}` / `{{prNumber}}`
        // placeholders — diff-inspection commands belong to the skill.
        // The build pipeline still runs the interpolator over the block,
        // so any new placeholders would silently survive into the prompt
        // and confuse the model. Guard against that.
        XCTAssertFalse(prompt.contains("{{prNumber}}"))
        XCTAssertFalse(prompt.contains("{{repo}}"))
        XCTAssertFalse(prompt.contains("{{branch}}"))
        XCTAssertFalse(prompt.contains("{{sha}}"))
    }

    func testBuildAppendsAllowlistAfterSchemaDirective() {
        let prompt = OrchestratorPrompt.build(
            repo: "Foo/Bar",
            prNumber: 7,
            branch: "feature/x",
            sha: "abc",
            jira: nil,
            changedFiles: ["src/Real.kt"]
        )
        guard let schemaIdx = prompt.range(of: OrchestratorPrompt.schemaDirective),
              let allowlistIdx = prompt.range(of: "Allowed file paths") else {
            XCTFail("Both schema directive and allowlist should appear in the prompt.")
            return
        }
        XCTAssertLessThan(schemaIdx.lowerBound, allowlistIdx.lowerBound)
        assertThat(prompt).contains("src/Real.kt")
    }

    func testBuildOmitsAllowlistWhenChangedFilesNil() {
        let prompt = OrchestratorPrompt.build(
            repo: "Foo/Bar",
            prNumber: 7,
            branch: "feature/x",
            sha: "abc",
            jira: nil
        )
        XCTAssertFalse(prompt.contains("Allowed file paths"))
    }
}
