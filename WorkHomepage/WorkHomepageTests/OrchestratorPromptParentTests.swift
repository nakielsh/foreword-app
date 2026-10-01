//
//  OrchestratorPromptParentTests.swift
//  WorkHomepageTests
//
//  Slice 11. Verifies the subtask-with-parent shape of `OrchestratorPrompt.build`:
//    - Parent attached → "subtask of <PARENT>" header, subtask block, parent block.
//    - Parent nil → format identical to slice 10 (Title / Type / Description).
//    - Empty subtask description → renders as the literal "(empty)".
//

import XCTest
@testable import WorkHomepage

final class OrchestratorPromptParentTests: XCTestCase {

    // MARK: - Helpers

    private func makeParent(
        key: String = "PROJ-100",
        summary: String = "Parent: redesign auth flow",
        description: String = "Long parent description with the real spec."
    ) -> JiraTicket {
        JiraTicket(
            key: key,
            summary: summary,
            description: description,
            status: "In Progress",
            issueType: "Story",
            priority: "High",
            parentKey: nil,
            parent: nil
        )
    }

    private func makeSubtask(
        key: String = "PROJ-200",
        summary: String = "Subtask: wire up the button",
        description: String,
        parent: JiraTicket?
    ) -> JiraTicket {
        JiraTicket(
            key: key,
            summary: summary,
            description: description,
            status: "To Do",
            issueType: "Sub-task",
            priority: "Medium",
            parentKey: parent?.key,
            parent: parent
        )
    }

    // MARK: - Parent attached

    func testPromptWithParentRendersSubtaskWithParentBlock() {
        let parent = makeParent()
        let subtask = makeSubtask(
            description: "Short note on the subtask.",
            parent: parent
        )
        let prompt = OrchestratorPrompt.build(
            repo: "acme/foo",
            prNumber: 42,
            branch: "feature/PROJ-200",
            sha: "deadbeef",
            jira: subtask
        )

        // Header line carries "subtask of <PARENT>".
        XCTAssertTrue(
            prompt.hasPrefix("Jira: PROJ-200 (subtask of PROJ-100)\n"),
            "prompt should open with the subtask key + parent key"
        )
        // Subtask block.
        XCTAssertTrue(prompt.contains("Subtask title: Subtask: wire up the button"))
        XCTAssertTrue(prompt.contains("Subtask description: Short note on the subtask."))
        // Parent block.
        XCTAssertTrue(prompt.contains("Parent PROJ-100 title: Parent: redesign auth flow"))
        XCTAssertTrue(prompt.contains("Parent description: Long parent description with the real spec."))
        // Subtask block strictly precedes the parent block, which strictly
        // precedes the PR-meta header.
        let subIdx = prompt.range(of: "Subtask title:")!.lowerBound
        let parIdx = prompt.range(of: "Parent PROJ-100 title:")!.lowerBound
        let prIdx = prompt.range(of: "You are reviewing PR")!.lowerBound
        XCTAssertLessThan(subIdx, parIdx)
        XCTAssertLessThan(parIdx, prIdx)
        // PR meta still appears with the Jira-context clause.
        XCTAssertTrue(prompt.contains("verify the diff matches the Jira description above"))
    }

    // MARK: - Empty subtask description renders as "(empty)"

    func testEmptySubtaskDescriptionRendersAsEmptySentinel() {
        let parent = makeParent()
        let subtask = makeSubtask(description: "", parent: parent)
        let prompt = OrchestratorPrompt.build(
            repo: "acme/foo",
            prNumber: 43,
            branch: "feature/PROJ-200",
            sha: "abc",
            jira: subtask
        )
        XCTAssertTrue(
            prompt.contains("Subtask description: (empty)"),
            "empty subtask description should render the literal '(empty)' sentinel"
        )
        // Parent description still present even though the subtask was empty.
        XCTAssertTrue(prompt.contains("Parent description: Long parent description with the real spec."))
    }

    // MARK: - Parent nil → slice 10 format unchanged

    func testParentNilMatchesSlice10Format() {
        let ticket = JiraTicket(
            key: "PROJ-123",
            summary: "Allow PEM-encoded keys",
            description: "First paragraph.\n\nSecond paragraph.",
            status: "In Progress",
            issueType: "Story",
            priority: "High",
            parentKey: nil,
            parent: nil
        )
        let prompt = OrchestratorPrompt.build(
            repo: "acme/foo",
            prNumber: 42,
            branch: "feature/PROJ-123",
            sha: "deadbeef",
            jira: ticket
        )

        // Exactly the slice 10 shape — same assertions as
        // OrchestratorJiraInjectionTests.testPromptIncludesFullJiraBlock.
        XCTAssertTrue(prompt.hasPrefix("Jira: PROJ-123\n"))
        XCTAssertTrue(prompt.contains("Title: Allow PEM-encoded keys"))
        XCTAssertTrue(prompt.contains("Type: Story  Status: In Progress  Priority: High"))
        XCTAssertTrue(prompt.contains("Description:\nFirst paragraph.\n\nSecond paragraph."))
        // None of the subtask-with-parent markers are present.
        XCTAssertFalse(prompt.contains("subtask of"), "no subtask-of header when parent is nil")
        XCTAssertFalse(prompt.contains("Subtask title:"), "no Subtask title line when parent is nil")
        XCTAssertFalse(prompt.contains("Parent description:"), "no Parent description block when parent is nil")
    }

    // MARK: - renderJiraBlock structural shape with parent
    //
    // Earlier slices pinned this to byte-exact output. Whitespace and
    // ordering of the two child fields are load-bearing (the model uses
    // them to associate description with title), but the inter-block
    // newline count is not — it can flex between 1 and 2. Assert structure
    // instead of exact bytes.

    func testRenderJiraBlockSubtaskWithParentContainsAllSectionsInOrder() {
        let parent = JiraTicket(
            key: "AB-1",
            summary: "Parent S",
            description: "Parent D",
            status: "Open",
            issueType: "Story",
            priority: "Low",
            parentKey: nil,
            parent: nil
        )
        let subtask = JiraTicket(
            key: "AB-2",
            summary: "Subtask S",
            description: "Subtask D",
            status: "Open",
            issueType: "Sub-task",
            priority: "Low",
            parentKey: "AB-1",
            parent: parent
        )
        let block = OrchestratorPrompt.renderJiraBlock(subtask)

        let pieces = [
            "Jira: AB-2 (subtask of AB-1)",
            "Subtask title: Subtask S",
            "Subtask description: Subtask D",
            "Parent AB-1 title: Parent S",
            "Parent description: Parent D"
        ]
        var lastIndex = block.startIndex
        for piece in pieces {
            guard let range = block.range(of: piece, range: lastIndex..<block.endIndex) else {
                XCTFail("missing piece '\(piece)' in: \(block)")
                return
            }
            lastIndex = range.upperBound
        }

        // Trailing newline so the next section is visually separated.
        assertThat(block.hasSuffix("\n")).isTrue()
    }
}
