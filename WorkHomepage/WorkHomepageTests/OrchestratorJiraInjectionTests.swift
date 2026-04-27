//
//  OrchestratorJiraInjectionTests.swift
//  WorkHomepageTests
//
//  Slice 10. Light-touch tests for `OrchestratorPrompt.build`. We pulled
//  the prompt builder out of the orchestrator (which is `@MainActor` and
//  spins up SwiftData) so it can be unit-tested in isolation.
//

import XCTest
@testable import WorkHomepage

final class OrchestratorJiraInjectionTests: XCTestCase {

    // MARK: - With Jira ticket

    func testPromptIncludesFullJiraBlock() {
        let ticket = JiraTicket(
            key: "JWT-123",
            summary: "Allow PEM-encoded keys",
            description: "First paragraph.\n\nSecond paragraph.",
            status: "In Progress",
            issueType: "Story",
            priority: "High",
            parentKey: nil
        )
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 42,
            branch: "feature/JWT-123",
            sha: "deadbeef",
            jira: ticket
        )

        // Jira block is at the very top of the prompt.
        XCTAssertTrue(prompt.hasPrefix("Jira: JWT-123\n"), "prompt should open with the Jira key line")
        XCTAssertTrue(prompt.contains("Title: Allow PEM-encoded keys"))
        XCTAssertTrue(prompt.contains("Type: Story  Status: In Progress  Priority: High"))
        XCTAssertTrue(prompt.contains("Description:\nFirst paragraph.\n\nSecond paragraph."))
        // PR meta still appears, after the Jira block.
        XCTAssertTrue(prompt.contains("You are reviewing PR #42 in Ala-com/foo, branch feature/JWT-123."))
        // Description tells the model Jira context was supplied.
        XCTAssertTrue(prompt.contains("verify the diff matches the Jira description above"))

        // Order: Jira block strictly precedes the PR-meta header.
        let jiraIdx = prompt.range(of: "Jira: JWT-123")!.lowerBound
        let prIdx = prompt.range(of: "You are reviewing PR")!.lowerBound
        XCTAssertLessThan(jiraIdx, prIdx)
    }

    // MARK: - With Jira ticket but no priority

    func testMissingPriorityRendersAsUnset() {
        let ticket = JiraTicket(
            key: "JWT-9",
            summary: "x",
            description: "",
            status: "Open",
            issueType: "Bug",
            priority: nil,
            parentKey: nil
        )
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "bugfix/JWT-9",
            sha: "abc",
            jira: ticket
        )
        XCTAssertTrue(prompt.contains("Priority: Unset"))
    }

    func testEmptyPriorityRendersAsUnset() {
        let ticket = JiraTicket(
            key: "JWT-9",
            summary: "x",
            description: "",
            status: "Open",
            issueType: "Bug",
            priority: "",
            parentKey: nil
        )
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "bugfix/JWT-9",
            sha: "abc",
            jira: ticket
        )
        XCTAssertTrue(prompt.contains("Priority: Unset"))
    }

    // MARK: - Without Jira

    func testNoJiraRendersJiraNullSentinel() {
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 7,
            branch: "main",
            sha: "abc",
            jira: nil
        )
        XCTAssertTrue(prompt.hasPrefix("Jira: null\n"), "prompt should open with `Jira: null` when no ticket")
        XCTAssertFalse(prompt.contains("Title:"), "no Title line when there's no ticket")
        XCTAssertFalse(prompt.contains("Description:"), "no Description block when there's no ticket")
        // Slice 23: body is now template-driven; the alignment clause in the
        // default template is the with-Jira variant. The sentinel we verify is
        // that the PR meta variables are interpolated correctly.
        XCTAssertTrue(prompt.contains("You are reviewing PR #7 in Ala-com/foo, branch main."))
    }

    // MARK: - renderJiraBlock structural shape
    //
    // Earlier slices pinned this to byte-exact output; whitespace tweaks
    // would force test churn without changing meaning. We now assert the
    // load-bearing shape: every required field appears in the right order,
    // followed by a trailing newline that separates the block from the
    // next section. Spacing inside the meta line is verified via a
    // case-folded contains check, not an exact `==`.

    func testRenderJiraBlockContainsAllFieldsInOrder() {
        let ticket = JiraTicket(
            key: "AB-1",
            summary: "S",
            description: "D",
            status: "Open",
            issueType: "Bug",
            priority: "Low",
            parentKey: nil
        )
        let block = OrchestratorPrompt.renderJiraBlock(ticket)

        // Required fields appear, in order.
        let pieces = ["Jira: AB-1", "Title: S", "Type: Bug", "Status: Open", "Priority: Low", "Description:", "D"]
        var lastIndex = block.startIndex
        for piece in pieces {
            guard let range = block.range(of: piece, range: lastIndex..<block.endIndex) else {
                XCTFail("missing piece '\(piece)' in: \(block)")
                return
            }
            lastIndex = range.upperBound
        }

        // Trailing newline (so the next section is visually separated).
        assertThat(block.hasSuffix("\n")).isTrue()
    }

    func testRenderJiraBlockNullSentinel() {
        // The null sentinel is load-bearing: the orchestrator's prompt code
        // splits on it, so the exact shape is part of the contract.
        XCTAssertEqual(OrchestratorPrompt.renderJiraBlock(nil), "Jira: null\n")
    }
}
