//
//  ReviewStoreFilterTests.swift
//  ForewordTests
//
//  Covers the worktree-existence filter applied by
//  `ReviewStore.markCompleted` when a `worktreeURL` is supplied. Drops
//  hallucinated paths and absolute paths before they reach SwiftData; the
//  count of dropped findings is surfaced via `Review.errorMessage` so the
//  modal can flag the cleanup to the user.
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class ReviewStoreFilterTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ReviewStoreFilterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self, CachedJiraTicket.self, PreReviewSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func makeFile(_ relPath: String) throws {
        let url = tempDir.appending(path: relPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "// fake".write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeSchemaFinding(file: String, title: String) -> SchemaFinding {
        SchemaFinding(
            severity: "minor",
            file: file,
            line: 1,
            endLine: nil,
            title: title,
            message: "m",
            suggestion: nil
        )
    }

    func testMarkCompletedDropsFindingsWhoseFileMissingInWorktree() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let review = store.addReview(
            prKey: "Foo/Bar#1",
            repoFullName: "Foo/Bar",
            prNumber: 1,
            headSha: "abc",
            headBranch: "feature/x"
        )

        try makeFile("src/Real.kt")
        let schema = ReviewSchema(
            summary: "s",
            verdict: "comment",
            findings: [
                makeSchemaFinding(file: "src/Real.kt", title: "keep"),
                makeSchemaFinding(file: "src/Hallucinated.kt", title: "drop-missing"),
                makeSchemaFinding(file: "/etc/passwd", title: "drop-absolute"),
                makeSchemaFinding(file: "", title: "drop-empty")
            ]
        )

        store.markCompleted(review, schema: schema, rawJSON: "{}", worktreeURL: tempDir)

        let descriptor = FetchDescriptor<Finding>()
        let saved = try context.fetch(descriptor)
        let savedTitles = saved.map { $0.title }.sorted()
        assertThat(savedTitles).isEqualTo(["keep"])
        let notice = try XCTUnwrap(review.filterNotice)
        assertThat(notice).contains("Filtered 3 finding(s)")
        assertThat(notice).contains("Hallucinated.kt")
        // errorMessage must stay nil — only the decode-failure path sets it,
        // and clobbering it would push the sheet into the raw-JSON view.
        XCTAssertNil(review.errorMessage)
    }

    func testMarkCompletedKeepsAllFindingsWhenNoWorktreeURLSupplied() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let review = store.addReview(
            prKey: "Foo/Bar#2",
            repoFullName: "Foo/Bar",
            prNumber: 2,
            headSha: "abc",
            headBranch: "feature/y"
        )

        let schema = ReviewSchema(
            summary: "s",
            verdict: "comment",
            findings: [
                makeSchemaFinding(file: "src/A.kt", title: "a"),
                makeSchemaFinding(file: "src/B.kt", title: "b")
            ]
        )

        store.markCompleted(review, schema: schema, rawJSON: "{}")

        let descriptor = FetchDescriptor<Finding>()
        let saved = try context.fetch(descriptor)
        assertThat(saved.count).isEqualTo(2)
        XCTAssertNil(review.errorMessage)
        XCTAssertNil(review.filterNotice)
    }
}
