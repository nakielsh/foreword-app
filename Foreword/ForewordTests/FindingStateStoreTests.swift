//
//  FindingStateStoreTests.swift
//  ForewordTests
//
//  Slice 08 — verify the SwiftData write path that flips `Finding.state`.
//
//  Two contracts pinned here:
//   1. `setState` round-trips: setting a state and reading it back from
//      the same context yields the new value.
//   2. State persists across context recreation against the same backing
//      `ModelContainer`, so the user's resolved/dismissed picks survive
//      app-relaunch in production (where the store is on-disk; here we use
//      an in-memory container that's still shared across two
//      `ModelContext`s in the same `Container`).
//   3. Unknown / typo state values are rejected (no-op) — the store guards
//      the legal vocabulary so a stray write can't corrupt the model.
//
//  Uses an in-memory `ModelContainer` per test so we never hit disk.
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class FindingStateStoreTests: XCTestCase {

    // MARK: - Fixture

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func insertFinding(
        in context: ModelContext,
        severity: String = "blocker",
        state: String = "open"
    ) -> Finding {
        let finding = Finding(
            severity: severity,
            file: "src/Foo.swift",
            line: 12,
            endLine: nil,
            title: "Force-unwrap",
            message: "Use guard let.",
            suggestion: nil,
            state: state,
            review: nil
        )
        context.insert(finding)
        try? context.save()
        return finding
    }

    // MARK: - Round-trip

    func testSetStateRoundTrip() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let finding = insertFinding(in: context)
        let store = FindingStateStore(context: context)

        XCTAssertEqual(finding.state, FindingState.open)

        store.setState(finding, to: FindingState.resolved)
        XCTAssertEqual(finding.state, FindingState.resolved)

        store.setState(finding, to: FindingState.dismissed)
        XCTAssertEqual(finding.state, FindingState.dismissed)

        store.setState(finding, to: FindingState.open)
        XCTAssertEqual(finding.state, FindingState.open)
    }

    // MARK: - Persistence across context recreation

    func testStatePersistsAcrossContextRecreation() throws {
        let container = try makeContainer()

        // Writer context: insert + flip state to resolved.
        let writer = ModelContext(container)
        let inserted = insertFinding(in: writer)
        let writerStore = FindingStateStore(context: writer)
        writerStore.setState(inserted, to: FindingState.resolved)
        try writer.save()
        let insertedID = inserted.id

        // Reader context: same container, fresh context. Re-fetch by id
        // and verify the state survived the boundary.
        let reader = ModelContext(container)
        let descriptor = FetchDescriptor<Finding>(
            predicate: #Predicate { $0.id == insertedID }
        )
        let fetched = try reader.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.state, FindingState.resolved)
    }

    // MARK: - Unknown values rejected

    func testUnknownStateIsRejected() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let finding = insertFinding(in: context, state: FindingState.open)
        let store = FindingStateStore(context: context)

        store.setState(finding, to: "frobnicated")
        XCTAssertEqual(finding.state, FindingState.open, "unknown state should be ignored")

        store.setState(finding, to: "")
        XCTAssertEqual(finding.state, FindingState.open, "empty state should be ignored")
    }

    // MARK: - Idempotence

    func testSettingSameStateIsIdempotent() throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let finding = insertFinding(in: context, state: FindingState.resolved)
        let store = FindingStateStore(context: context)

        store.setState(finding, to: FindingState.resolved)
        store.setState(finding, to: FindingState.resolved)
        XCTAssertEqual(finding.state, FindingState.resolved)
    }
}
