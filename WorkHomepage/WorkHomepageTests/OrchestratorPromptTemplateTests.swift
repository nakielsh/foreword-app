//
//  OrchestratorPromptTemplateTests.swift
//  WorkHomepageTests
//
//  Slice 23 — Custom Review Prompt Template.
//
//  Extends the existing orchestrator prompt coverage to verify:
//    - Custom template vars are interpolated correctly.
//    - Missing schema directive is auto-appended.
//    - Jira block placement is unchanged regardless of custom template.
//    - The no-Jira path still works with a custom template.
//

import XCTest
@testable import WorkHomepage

final class OrchestratorPromptTemplateTests: XCTestCase {

    // MARK: - Helpers

    private func makeStore(template: String) -> ReviewPromptStore {
        let suite = "OrchestratorPromptTemplateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ReviewPromptStore(defaults: defaults)
        store.setCurrent(template)
        return store
    }

    private func makeTicket() -> JiraTicket {
        JiraTicket(
            key: "JWT-1",
            summary: "Test ticket",
            description: "Test description.",
            status: "In Progress",
            issueType: "Story",
            priority: "High",
            parentKey: nil
        )
    }

    // MARK: - Variable interpolation

    func testCustomTemplateVarsAreInterpolated() {
        let store = makeStore(template: "Reviewing PR {{prNumber}} in {{repo}} on {{branch}} at {{sha}}.")
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 42,
            branch: "feature/JWT-1",
            sha: "deadbeef",
            jira: nil,
            store: store
        )
        XCTAssertTrue(prompt.contains("Reviewing PR 42 in Ala-com/foo on feature/JWT-1 at deadbeef."))
    }

    func testCustomTemplateLeavesUnknownVarsLiteral() {
        let store = makeStore(template: "{{repo}} {{unknownVar}}")
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "main",
            sha: "abc",
            jira: nil,
            store: store
        )
        XCTAssertTrue(prompt.contains("Ala-com/foo {{unknownVar}}"))
    }

    // MARK: - Schema directive auto-append

    func testSchemaDirectiveIsAutoAppendedWhenAbsentFromTemplate() {
        let store = makeStore(template: "Review PR {{prNumber}} in {{repo}}.")
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "main",
            sha: "abc",
            jira: nil,
            store: store
        )
        XCTAssertTrue(
            prompt.contains(OrchestratorPrompt.schemaDirective),
            "schema directive should be auto-appended when absent from the user template"
        )
    }

    func testSchemaDirectiveIsNotDuplicatedWhenPresentInTemplate() {
        let template = "Do your thing.\n\nReturn JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files."
        let store = makeStore(template: template)
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "main",
            sha: "abc",
            jira: nil,
            store: store
        )
        let occurrences = prompt.components(separatedBy: OrchestratorPrompt.schemaDirective).count - 1
        XCTAssertEqual(occurrences, 1, "schema directive must appear exactly once")
    }

    // MARK: - Jira block placement

    func testJiraBlockPrecedesCustomBodyRegardlessOfTemplate() {
        let store = makeStore(template: "My custom body for {{repo}}.")
        let ticket = makeTicket()
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 7,
            branch: "feature/JWT-1",
            sha: "abc",
            jira: ticket,
            store: store
        )
        XCTAssertTrue(prompt.hasPrefix("Jira: JWT-1\n"))
        let jiraIdx = prompt.range(of: "Jira: JWT-1")!.lowerBound
        let bodyIdx = prompt.range(of: "My custom body")!.lowerBound
        XCTAssertLessThan(jiraIdx, bodyIdx)
    }

    func testNoJiraBlockWithCustomTemplate() {
        let store = makeStore(template: "Custom body only, no jira.")
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 9,
            branch: "main",
            sha: "abc",
            jira: nil,
            store: store
        )
        XCTAssertTrue(prompt.hasPrefix("Jira: null\n"))
        XCTAssertTrue(prompt.contains("Custom body only, no jira."))
    }

    // MARK: - Direct template overload

    func testBuildWithTemplateParameterDoesNotPersist() {
        let store = ReviewPromptStore()
        // Build with explicit template — should NOT save to store.
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "main",
            sha: "abc",
            jira: nil,
            template: "Direct template: {{repo}}."
        )
        XCTAssertTrue(prompt.contains("Direct template: Ala-com/foo."))
        // Store's current value is unaffected.
        let storeCurrent = store.current()
        XCTAssertFalse(
            storeCurrent.hasPrefix("Direct template"),
            "build(template:) must not persist to UserDefaults"
        )
    }

    func testBuildWithTemplateAutoAppendsSchemaDirectiveWhenAbsent() {
        let prompt = OrchestratorPrompt.build(
            repo: "Ala-com/foo",
            prNumber: 1,
            branch: "main",
            sha: "abc",
            jira: nil,
            template: "No directive here."
        )
        XCTAssertTrue(prompt.contains(OrchestratorPrompt.schemaDirective))
    }
}
