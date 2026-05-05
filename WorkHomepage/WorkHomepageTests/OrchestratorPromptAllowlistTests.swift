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

    func testRenderAllowlistRejectsFilesystemExistenceAsPRMembership() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock(["src/A.kt"])
        // Model previously globbed the worktree, found pre-existing files
        // (e.g. S3Facade.kt), and claimed they were "part of the PR" even
        // though the PR didn't touch them. The "filesystem ≠ PR membership"
        // note must be present to head that off.
        assertThat(rendered).contains("Existence in the worktree's filesystem is NOT membership in the PR")
        assertThat(rendered).contains("Read")
        assertThat(rendered).contains("Glob")
    }

    func testRenderAllowlistOffersThreeDotGitDiffAsAlternative() {
        let rendered = OrchestratorPrompt.renderAllowlistBlock(["src/A.kt"])
        // Three-dot diff is the merge-base form — matches what GitHub
        // considers the PR diff. Two-dot is a trap (includes commits added
        // to main since the PR branched). The prompt MUST recommend `...`
        // and warn against `..`.
        assertThat(rendered).contains("git diff origin/main...HEAD")
        assertThat(rendered).contains("three dots")
        assertThat(rendered).contains("two dots")
    }

    func testBuildInterpolatesAllowlistPlaceholders() {
        let prompt = OrchestratorPrompt.build(
            repo: "Foo/Bar",
            prNumber: 42,
            branch: "feature/x",
            sha: "abc",
            jira: nil,
            changedFiles: ["src/Real.kt"]
        )
        // Placeholders in the allowlist's "how to inspect" section MUST be
        // interpolated, otherwise the model sees literal {{repo}} / {{prNumber}}
        // in its instructions and ignores them.
        assertThat(prompt).contains("gh pr diff 42 --repo Foo/Bar")
        XCTAssertFalse(prompt.contains("{{prNumber}}"))
        XCTAssertFalse(prompt.contains("{{repo}}"))
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
