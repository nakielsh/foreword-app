//
//  ReviewOrchestratorParallelStartTests.swift
//  ForewordTests
//
//  Stress test for the concurrency-cap invariant. Existing
//  `ReviewOrchestratorConcurrencyTests` mutates `AppSettings.standard`
//  to drive the cap; that's the shared-state mutation the wave-1 review
//  flagged. This file uses the new `init(pipeline:concurrencyCap:)` DI
//  seam exclusively — `AppSettings.standard` is never touched.
//
//  Invariant under test:
//
//    At every point during a multi-start storm, `running.count <= cap`.
//    Reviews queued behind the cap eventually drain in FIFO order.
//
//  Methodology:
//   - Spin up an orchestrator with cap=3 and a deterministic pipeline
//     that parks each review on a per-id gate.
//   - Dispatch 25 `start(...)` calls in a tight loop. Each registers
//     the review and either places it into `running` (if under cap) or
//     `queued` (otherwise).
//   - Observe `running.count` repeatedly during the storm and after
//     each gate release; assert it never exceeds the cap.
//

import XCTest
import SwiftData
@testable import Foreword

@MainActor
final class ReviewOrchestratorParallelStartTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    /// Per-review gate. The pipeline closure parks until `release()` is
    /// called; the orchestrator can then advance the FIFO.
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

    @MainActor
    private final class FakePipeline {
        // Gate-per-review. The map MUST tolerate release-before-pipeline
        // (test calls `release(id)` before the orchestrator has dispatched
        // the pipeline closure) and pipeline-before-release (the closure
        // creates the gate first; the test releases later). Either way we
        // store one gate per id and resume on first release.
        private var gates: [UUID: Gate] = [:]

        private func gate(for id: UUID) -> Gate {
            if let existing = gates[id] { return existing }
            let g = Gate()
            gates[id] = g
            return g
        }

        var pipeline: @MainActor (PipelineInput) async -> Void {
            { [weak self] input in
                guard let self else { return }
                let g = self.gate(for: input.review.id)
                await g.wait()
                if !input.cancellation.isCancelled {
                    input.store.markCompleted(input.review, schema: nil, rawJSON: "{}")
                }
            }
        }

        func release(_ id: UUID) {
            gate(for: id).release()
        }
    }

    // MARK: - Cap=3 storm: running.count never exceeds 3

    func testRunningNeverExceedsCapDuringMultiStartStorm() async throws {
        let cap = 3
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(
            pipeline: fake.pipeline,
            concurrencyCap: { cap }
        )

        var ids: [UUID] = []

        // Phase 1: dispatch 25 starts. Track running.count after each
        // call — the orchestrator must never let it exceed `cap`.
        var observedRunningCounts: [Int] = []
        for n in 1...25 {
            let r = await orch.start(
                repo: "org/a",
                prNumber: n,
                branch: "feature/x",
                sha: "deadbeef",
                store: store
            )
            ids.append(r.id)
            observedRunningCounts.append(orch.running.count)
            // Snapshot under-the-hood: every observation must respect the cap.
            assertThat(orch.running.count).isLessThanOrEqualTo(cap)
        }

        // After the storm: exactly cap running, the rest queued.
        assertThat(orch.running.count).isEqualTo(cap)
        assertThat(orch.queued.count).isEqualTo(25 - cap)

        // Storm assertion (post-hoc): every observed count is <= cap.
        for c in observedRunningCounts {
            assertThat(c).isLessThanOrEqualTo(cap)
        }

        // Phase 2: drain. Release each review's gate in FIFO id order. The
        // orchestrator promotes one queued review per drain. Cap invariant
        // must hold after each.
        for id in ids {
            // Wait until this id is actually running before releasing — the
            // post-completion drain hops the main actor a few times.
            let started = await pollUntil(timeoutSeconds: 5.0) {
                orch.running.contains(where: { $0.id == id })
            }
            assertThat(started).isTrue()
            fake.release(id)
            // After each release, give the orchestrator's finishRunning +
            // drainQueue room to land before observing.
            for _ in 0..<5 {
                assertThat(orch.running.count).isLessThanOrEqualTo(cap)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        // Final state: nothing running, nothing queued. Generous timeout
        // because the chain `release → resume → markCompleted → Task body
        // exit → finishRunning → drainQueue` involves several main-actor
        // hops per release.
        let drained = await pollUntil(timeoutSeconds: 10.0) {
            orch.running.isEmpty && orch.queued.isEmpty
        }
        assertThat(drained).isTrue()
        assertThat(orch.running).isEmpty()
        assertThat(orch.queued).isEmpty()
    }

    // MARK: - Cap mid-flight changes only affect future starts

    /// The `concurrencyCap:` provider is consulted at decision time — flipping
    /// it mid-flight reduces the post-flip start surface but does NOT kill
    /// in-flight rows. Pin that.
    func testCapReductionDoesNotKillInFlight() async throws {
        // Box the cap so the closure read sees mutations through reference
        // semantics — a plain `var` capture would be ambiguous under
        // strict-concurrency.
        final class CapBox { var value: Int = 3 }
        let capBox = CapBox()
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = ReviewStore(context: context)
        let fake = FakePipeline()
        let orch = ReviewOrchestrator(
            pipeline: fake.pipeline,
            concurrencyCap: { capBox.value }
        )

        var ids: [UUID] = []
        for n in 1...3 {
            let r = await orch.start(
                repo: "org/a",
                prNumber: n,
                branch: "feature/x",
                sha: "deadbeef",
                store: store
            )
            ids.append(r.id)
        }
        assertThat(orch.running.count).isEqualTo(3)

        // Reduce cap while three are running. None should be killed; new
        // starts should immediately queue.
        capBox.value = 1

        let r4 = await orch.start(
            repo: "org/a",
            prNumber: 4,
            branch: "feature/x",
            sha: "deadbeef",
            store: store
        )
        assertThat(orch.running.count).isEqualTo(3) // untouched
        assertThat(orch.queued.map(\.id)).containsExactly([r4.id])

        // Drain in id order; the new cap=1 means only ONE will be running
        // at a time after the first three drain.
        for id in ids {
            fake.release(id)
        }
        // Wait until 3 finish + r4 promoted (cap reduced to 1).
        await pollUntil(timeoutSeconds: 5.0) {
            orch.running.contains(where: { $0.id == r4.id })
        }
        assertThat(orch.running.count).isEqualTo(1)
        fake.release(r4.id)
        await pollUntil(timeoutSeconds: 5.0) { orch.running.isEmpty }
    }
}
