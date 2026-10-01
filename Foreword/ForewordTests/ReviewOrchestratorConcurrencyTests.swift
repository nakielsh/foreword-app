//
//  ReviewOrchestratorConcurrencyTests.swift
//  ForewordTests
//
//  Slice 13 — concurrency cap, queue, cancellation.
//
//  Drives a `ReviewOrchestrator` constructed with an injected pipeline
//  closure so we never spawn a real `claude` process. The closure simulates
//  the relevant pipeline behaviour: it waits on a per-review continuation
//  the test controls, observes the cancellation flag, and persists a
//  terminal state (`completed` / `cancelled`) via the supplied store.
//
//  Contract this exercises:
//   - Cap=1 → one running review at a time, FIFO drain on completion.
//   - Cap=3 → up to three running, the rest queued in FIFO order.
//   - Queued cancel → state cancelled, never enters running, pipeline
//     never invoked for that review.
//   - Running cancel → cooperative cancellation flag flips, pipeline
//     observes it, review reaches `cancelled` cleanly.
//   - State machine guard: never transitions queued → completed without
//     passing through running.
//   - `clearCurrent()` is refused while `current?.state == "running"`.
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class ReviewOrchestratorConcurrencyTests: XCTestCase {

    // MARK: - Fixtures

    /// In-memory SwiftData container so we never touch disk.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Per-test UserDefaults suite so we can set a cap without touching the
    /// developer's actual settings. The orchestrator reads
    /// `AppSettings.concurrencyCap` from `.standard`, so we override
    /// `.standard` for the duration of the test via a controllable suite.
    /// AppSettings has no DI seam for the suite name; the simplest safe
    /// approach is to set the cap on `.standard` and restore after.
    private var savedCap: Int = AppSettings.concurrencyCapDefault

    override func setUp() {
        super.setUp()
        savedCap = AppSettings.concurrencyCap
    }

    override func tearDown() {
        AppSettings.concurrencyCap = savedCap
        super.tearDown()
    }

    /// One slot per active pipeline. The injected closure parks on `gate`
    /// until the test calls `release()`. The cancellation flag lets the
    /// pipeline observe a cancel without us racing against the gate.
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var alreadyReleased = false

        func wait() async {
            await withCheckedContinuation { cont in
                if alreadyReleased {
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        }

        func release() {
            if let c = continuation {
                continuation = nil
                c.resume()
            } else {
                alreadyReleased = true
            }
        }
    }

    /// A test pipeline factory that publishes per-review gates. Each call to
    /// `pipeline(input)` registers a new gate keyed on `Review.id`. The
    /// closure waits on the gate, then either marks the review `completed`
    /// (default) or, if cancellation flipped while we were waiting, returns
    /// without persisting findings — leaving the orchestrator's
    /// `cancel(_:)` to flip the row to `cancelled`.
    @MainActor
    private final class FakePipeline {
        private(set) var startedReviewIDs: [UUID] = []
        private(set) var observedCancellations: [UUID] = []
        private var gates: [UUID: Gate] = [:]

        var pipeline: @MainActor (PipelineInput) async -> Void {
            { [weak self] input in
                guard let self else { return }
                self.startedReviewIDs.append(input.review.id)
                let gate = Gate()
                self.gates[input.review.id] = gate
                await gate.wait()
                if input.cancellation.isCancelled {
                    // Honour the cancellation — bail without persisting.
                    self.observedCancellations.append(input.review.id)
                    return
                }
                // Default happy path: mark completed via the supplied store.
                input.store.markCompleted(
                    input.review,
                    schema: nil,
                    rawJSON: "{}"
                )
            }
        }

        /// Releases the gate for `id`; if the pipeline hasn't reached the
        /// gate yet (race), the release is queued.
        func release(_ id: UUID) {
            if let g = gates[id] {
                g.release()
            } else {
                // Pre-create a released gate so the upcoming wait returns
                // immediately.
                let g = Gate()
                g.release()
                gates[id] = g
            }
        }

        /// Wait until at least one of `ids` has been observed by the
        /// pipeline (i.e. the orchestrator has dispatched it). Polls the
        /// MainActor at a millisecond cadence; tests use this to deflake
        /// the boundary between "Task created" and "Task body running".
        func waitForStart(of id: UUID, timeoutSeconds: Double = 2.0) async {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while !startedReviewIDs.contains(id) {
                if Date() > deadline { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        /// Polling helper: spin briefly so the orchestrator's post-pipeline
        /// `finishRunning` housekeeping can run on the main actor.
        func yieldOnce() async {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Insert a Review row directly via the orchestrator's `start(...)`. The
    /// orchestrator owns insertion via `ReviewStore.addReview`, so this is
    /// the same path production uses.
    @discardableResult
    private func startOne(
        orch: ReviewOrchestrator,
        store: ReviewStore,
        repo: String,
        prNumber: Int
    ) async -> Review {
        await orch.start(
            repo: repo,
            prNumber: prNumber,
            branch: "feature/x",
            sha: "deadbeef",
            store: store
        )
    }

    // MARK: - Cap = 1

    func testCapOneRunsSeriallyAndDrainsFifo() async throws {
        AppSettings.concurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        let r2 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 2)
        let r3 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 3)

        // r1 is running, r2/r3 queued in FIFO order.
        assertThat(orch.running.map(\.id)).containsExactly([r1.id])
        assertThat(orch.queued.map(\.id)).containsExactly([r2.id, r3.id])
        assertThat(r1.state).isEqualTo("running")
        assertThat(r2.state).isEqualTo("queued")
        assertThat(r3.state).isEqualTo("queued")
        assertThat(orch.inFlightCount).isEqualTo(3)

        // Wait for r1 to actually enter the pipeline, then complete it.
        await fake.waitForStart(of: r1.id)
        fake.release(r1.id)
        // Yield until r1 has finished and r2 has been promoted.
        await pollUntil { orch.running.contains(where: { $0.id == r2.id }) }

        assertThat(orch.running.map(\.id)).containsExactly([r2.id])
        assertThat(r1.state).isEqualTo("completed")
        assertThat(r2.state).isEqualTo("running")
        assertThat(r3.state).isEqualTo("queued")

        await fake.waitForStart(of: r2.id)
        fake.release(r2.id)
        await pollUntil { orch.running.contains(where: { $0.id == r3.id }) }

        assertThat(orch.running.map(\.id)).containsExactly([r3.id])
        assertThat(r2.state).isEqualTo("completed")
        assertThat(r3.state).isEqualTo("running")

        await fake.waitForStart(of: r3.id)
        fake.release(r3.id)
        await pollUntil { orch.running.isEmpty && orch.queued.isEmpty }

        assertThat(r3.state).isEqualTo("completed")
        assertThat(orch.inFlightCount).isEqualTo(0)
    }

    // MARK: - Cap = 3

    func testCapThreeRunsThreeAndQueuesTheRest() async throws {
        AppSettings.concurrencyCap = 3
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        var ids: [UUID] = []
        for n in 1...5 {
            let r = await startOne(orch: orch, store: store, repo: "org/a", prNumber: n)
            ids.append(r.id)
        }

        assertThat(orch.running.count).isEqualTo(3)
        assertThat(orch.queued.count).isEqualTo(2)
        assertThat(orch.running.map(\.id)).containsExactly(Array(ids.prefix(3)))
        assertThat(orch.queued.map(\.id)).containsExactly(Array(ids.suffix(2)))

        // Release the first running one — the next queued should promote.
        await fake.waitForStart(of: ids[0])
        fake.release(ids[0])
        await pollUntil { orch.running.contains(where: { $0.id == ids[3] }) }

        assertThat(orch.running.count).isEqualTo(3)
        assertThat(orch.queued.count).isEqualTo(1)
        assertThat(orch.queued.first?.id).isEqualTo(ids[4])
    }

    // MARK: - Cancel queued

    func testCancelQueuedDoesNotEnterRunning() async throws {
        AppSettings.concurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        let r2 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 2)

        assertThat(r1.state).isEqualTo("running")
        assertThat(r2.state).isEqualTo("queued")

        orch.cancel(r2)

        assertThat(r2.state).isEqualTo("cancelled")
        assertThat(orch.queued).isEmpty()
        assertThat(orch.running.map(\.id)).containsExactly([r1.id])

        // Pipeline must never have been invoked for r2.
        assertThat(fake.startedReviewIDs).doesNotContain(r2.id)

        // Sanity: completing r1 doesn't resurrect r2.
        await fake.waitForStart(of: r1.id)
        fake.release(r1.id)
        await pollUntil { orch.running.isEmpty }

        assertThat(fake.startedReviewIDs).doesNotContain(r2.id)
        assertThat(r2.state).isEqualTo("cancelled")
    }

    // MARK: - Cancel running

    func testCancelRunningTransitionsToCancelledAndDrainsQueue() async throws {
        AppSettings.concurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        let r2 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 2)

        await fake.waitForStart(of: r1.id)
        // The pipeline for r1 is parked in `gate.wait()`. Cancel it.
        orch.cancel(r1)

        assertThat(r1.state).isEqualTo("cancelled")
        // r2 should have been promoted to running by the cancel-driven drain.
        assertThat(orch.running.map(\.id)).containsExactly([r2.id])
        assertThat(r2.state).isEqualTo("running")

        // Now release r1's gate so its pipeline body can complete. It must
        // observe the cancellation flag and exit without overwriting the
        // `cancelled` state with a `completed` save.
        fake.release(r1.id)
        await fake.yieldOnce()
        assertThat(r1.state).isEqualTo("cancelled")
        assertThat(fake.observedCancellations).contains(r1.id)

        // Drain r2 too so the test leaves no dangling tasks.
        await fake.waitForStart(of: r2.id)
        fake.release(r2.id)
        await pollUntil { orch.running.isEmpty }
    }

    // MARK: - State machine guard

    func testQueuedNeverTransitionsDirectlyToCompleted() async throws {
        AppSettings.concurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)

        // Recording pipeline: capture every state transition we see by
        // inspecting `Review.state` at pipeline-entry time. If the
        // orchestrator ever dispatched a queued review without first
        // promoting it to `running`, the recorder would see a `queued` state
        // when its closure runs — but the orchestrator flips to `running`
        // before dispatching, so we expect every entry to read `running`.
        var observedEntryStates: [String] = []
        let pipeline: @MainActor (PipelineInput) async -> Void = { input in
            observedEntryStates.append(input.review.state)
            input.store.markCompleted(input.review, schema: nil, rawJSON: "{}")
        }
        let orch = ReviewOrchestrator(pipeline: pipeline)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        let r2 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 2)
        let r3 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 3)

        await pollUntil(timeoutSeconds: 2.0) {
            r1.state == "completed" && r2.state == "completed" && r3.state == "completed"
        }

        // Every pipeline invocation saw `running`, never `queued`.
        assertThat(observedEntryStates).hasSize(3)
        assertThat(observedEntryStates).allEqualTo("running")
    }

    // MARK: - clearCurrent guard

    func testClearCurrentRefusedWhileCurrentIsRunning() async throws {
        AppSettings.concurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        await fake.waitForStart(of: r1.id)

        XCTAssertEqual(orch.current?.id, r1.id)
        orch.clearCurrent()
        XCTAssertNotNil(orch.current, "clearCurrent must not nil-out a still-running review")
        XCTAssertEqual(orch.current?.id, r1.id)

        // Once the run completes, clearCurrent should succeed.
        fake.release(r1.id)
        await pollUntil { orch.running.isEmpty }
        orch.clearCurrent()
        XCTAssertNil(orch.current)
    }

    // MARK: - inFlightCount

    func testInFlightCountReflectsQueuedAndRunning() async throws {
        AppSettings.concurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(pipeline: fake.pipeline)

        XCTAssertEqual(orch.inFlightCount, 0)

        let r1 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 1)
        let r2 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 2)
        let r3 = await startOne(orch: orch, store: store, repo: "org/a", prNumber: 3)

        XCTAssertEqual(orch.inFlightCount, 3)
        XCTAssertEqual(orch.running.count, 2)
        XCTAssertEqual(orch.queued.count, 1)

        // Cleanup: drain so we don't leak tasks.
        await fake.waitForStart(of: r1.id)
        fake.release(r1.id)
        fake.release(r2.id)
        await pollUntil { orch.running.contains(where: { $0.id == r3.id }) }
        await fake.waitForStart(of: r3.id)
        fake.release(r3.id)
        await pollUntil { orch.inFlightCount == 0 }
    }

    // MARK: - Polling helper

    /// Spins on the main actor until `cond()` returns true or `timeoutSeconds`
    /// elapses. Used to deflake "the orchestrator processed an event" without
    /// reaching for `XCTestExpectation` for every step.
    private func pollUntil(
        timeoutSeconds: Double = 2.0,
        _ cond: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !cond() {
            if Date() > deadline { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// AssertJ-flavoured helpers consolidated into Helpers/Assertions.swift —
// the per-file duplicates have been removed in favour of the shared shim.
