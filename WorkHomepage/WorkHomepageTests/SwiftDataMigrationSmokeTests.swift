//
//  SwiftDataMigrationSmokeTests.swift
//  WorkHomepageTests
//
//  Smoke test that the current SwiftData schema can be opened on a store
//  that already contains the entity rows we expect, without losing data.
//
//  The repo doesn't yet maintain a `VersionedSchema` history (there is no
//  `MigrationPlan`) — every model bump silently wipes user data on first
//  launch under the current `Schema(...)` setup. We don't want to add a
//  versioned schema as a side effect of writing a test (that's a code
//  change with persistence consequences); but we DO want a regression
//  fence that fires the moment somebody starts a migration plan.
//
//  Strategy:
//   1. Build an on-disk container against the current `Schema([Review.self,
//      Finding.self])`. Insert one Review with one Finding, save, close.
//   2. Re-open the same on-disk store with the same schema. The Review
//      row + the Finding row must be intact.
//   3. The same operation against an in-memory store also works (sanity).
//
//  When a versioned schema lands later, this test should be updated to
//  open with the OLDER schema in step (1) and re-open with the CURRENT
//  schema in step (2), asserting the migration plan ran and didn't drop
//  rows. For now it pins "open-close-open does not wipe", which is the
//  weakest guarantee we can ship without a `MigrationPlan` in source.
//

import XCTest
import SwiftData
@testable import WorkHomepage

@MainActor
final class SwiftDataMigrationSmokeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SwiftDataMigrationSmoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - On-disk open/close/open preserves rows

    /// Insert into an on-disk store, close, re-open with the same schema.
    /// The rows must survive — basic sanity that SwiftData isn't wiping
    /// the file. When a versioned schema arrives, this becomes the
    /// "migration ran cleanly" smoke fence.
    func testOnDiskReopenPreservesReviewAndFinding() throws {
        let storeURL = tempDir.appendingPathComponent("store.sqlite")
        let schema = Schema([Review.self, Finding.self])

        // Pass 1: write rows.
        let reviewID = UUID()
        let findingID = UUID()
        do {
            let config = ModelConfiguration(schema: schema, url: storeURL)
            let container = try ModelContainer(for: schema, configurations: [config])
            let context = ModelContext(container)

            let review = Review(
                id: reviewID,
                prKey: "org/repo#7",
                repoFullName: "org/repo",
                prNumber: 7,
                headSha: "deadbeef",
                headBranch: "feature/x",
                state: "completed",
                summary: "ok",
                verdict: "approve"
            )
            let finding = Finding(
                id: findingID,
                severity: "minor",
                file: "src/foo.swift",
                line: 10,
                title: "nit",
                message: "use static import",
                review: review
            )
            review.findings = [finding]
            context.insert(review)
            context.insert(finding)
            try context.save()
        }

        // Pass 2: re-open against the same file with the same schema.
        let config2 = ModelConfiguration(schema: schema, url: storeURL)
        let container2 = try ModelContainer(for: schema, configurations: [config2])
        let context2 = ModelContext(container2)

        let reviews = try context2.fetch(FetchDescriptor<Review>())
        let findings = try context2.fetch(FetchDescriptor<Finding>())

        assertThat(reviews).hasSize(1)
        assertThat(findings).hasSize(1)

        let r = reviews[0]
        assertThat(r.id).isEqualTo(reviewID)
        assertThat(r.prKey).isEqualTo("org/repo#7")
        assertThat(r.state).isEqualTo("completed")

        let f = findings[0]
        assertThat(f.id).isEqualTo(findingID)
        assertThat(f.severity).isEqualTo("minor")
        // Cascade relationship: findings still know their review.
        assertThat(f.review?.id == reviewID).isTrue()
    }

    // MARK: - In-memory sanity

    func testInMemoryContainerSupportsCRUD() throws {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let review = Review(
            prKey: "x/y#1",
            repoFullName: "x/y",
            prNumber: 1,
            headSha: "abc",
            headBranch: "main"
        )
        context.insert(review)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Review>())
        assertThat(fetched).hasSize(1)
    }
}
