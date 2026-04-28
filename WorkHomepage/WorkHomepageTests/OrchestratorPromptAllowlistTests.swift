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
        assertThat(rendered).contains("changes 300 files")
        // First and 200th present, 201st absent.
        assertThat(rendered).contains("  - f0.kt")
        assertThat(rendered).contains("  - f199.kt")
        XCTAssertFalse(rendered.contains("  - f200.kt"))
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
