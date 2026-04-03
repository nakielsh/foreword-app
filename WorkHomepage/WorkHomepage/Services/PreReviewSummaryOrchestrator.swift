//
//  PreReviewSummaryOrchestrator.swift
//  WorkHomepage
//
//  Slice 25 — Pre-Review Summary concurrency pool + retry.
//
//  Wraps `PreReviewSummaryRunner` with a dedicated concurrency pool that is
//  independent of the Review pool managed by `ReviewOrchestrator`. Each
//  `start(...)` call either short-circuits on a cache hit, enters `running`
//  immediately (if under `AppSettings.summaryConcurrencyCap`), or enters
//  `queued` and waits in FIFO order.
//
//  Architecture (ADR-0002):
//   - Separate from the Review pipeline: no worktree, no clone, independent
//     cap, independent state machine.
//   - Keyed by `SummaryRunID` (UUID). Each `start(...)` call returns a new ID
//     even for the same PR — callers hold the ID and observe `state(_:)` on it.
//   - `SummaryRunState` is `@Published` via a `[SummaryRunID: SummaryRunState]`
//     map so SwiftUI views can observe per-card state.
//   - Cache hits resolve synchronously: `state(id)` immediately returns
//     `.cached(display)` and the `events(id)` stream emits one synthetic event
//     then closes.
//   - On `.result` the orchestrator persists via `PreReviewSummaryStore` before
//     publishing `.cached`.
//   - On `.error` the orchestrator publishes `.failed(message:)` — the card can
//     call `start(...)` again to retry; each retry issues a fresh `SummaryRunID`
//     so there is no stale state to clear.
//   - `cancel(id)`: queued → immediate terminal (id removed from states map);
//     running → task cancel + cooperative termination via the runner's
//     `onTermination` handler.
//   - The cap is read at decision time; reducing it mid-flight does not kill
//     running summaries.
//
//  ## Singleton setup
//
//  `PreReviewSummaryOrchestrator.shared` is a process-wide singleton. Because
//  the orchestrator holds a `PreReviewSummaryStore` (which needs a
//  `ModelContext`), callers must call `configure(context:)` once a
//  `ModelContext` is available before the first `start(...)` call. In practice
//  `ReviewsTab.body` does this on `.task`. The singleton guards against
//  unconfigured access by using a no-op store until configured.
//

import Combine
import Foundation
import SwiftData

// MARK: - Public types

typealias SummaryRunID = UUID

/// Per-card lifecycle state published by `PreReviewSummaryOrchestrator`.
enum SummaryRunState: Equatable {
    /// No run in progress (initial state, or after a terminal run is cleared).
    case idle
    /// Waiting for a concurrency slot. `ahead` = position in the FIFO queue (0-based).
    case queued(ahead: Int)
    /// Claude is running.
    case running
    /// A cached result is available (immediate cache hit, or just completed).
    case cached(PreReviewSummaryDisplay)
    /// The run failed. `message` is shown inline; the card should offer retry.
    case failed(message: String)
}

/// Display-oriented value extracted from `PreReviewSummary`. Equatable for
/// `SummaryRunState` conformance without pulling in the SwiftData model.
struct PreReviewSummaryDisplay: Equatable {
    let what: String
    let why: String
    let risk: String
}

// MARK: - Orchestrator

/// Manages a bounded pool of concurrent `PreReviewSummaryRunner` invocations.
/// All mutation happens on the `@MainActor` so `@Published` state changes are
/// visible to SwiftUI without explicit dispatch.
@MainActor
final class PreReviewSummaryOrchestrator: ObservableObject {

    // MARK: - Singleton

    /// Process-wide singleton. Call `configure(context:)` before first use.
    static let shared = PreReviewSummaryOrchestrator(
        runnerFactory: { repo, prNumber, headSha in
            PreReviewSummaryRunner.summarize(repo: repo, prNumber: prNumber, headSha: headSha)
        },
        store: nil
    )

    /// Reconfigure the singleton's `PreReviewSummaryStore` when a new
    /// `ModelContext` is available (called from `ReviewsTab`). Idempotent —
    /// safe to call on every `.task` execution.
    func configure(context: ModelContext) {
        self.liveStore = PreReviewSummaryStore(context: context)
    }

    // MARK: - Published state

    /// Per-run state. SwiftUI views key off the `SummaryRunID` they received
    /// from `start(...)` and observe this map for state transitions.
    @Published private(set) var states: [SummaryRunID: SummaryRunState] = [:]

    // MARK: - Internal state

    /// IDs currently executing a runner invocation.
    private var runningIDs: [SummaryRunID] = []

    /// FIFO queue of pending (not-yet-started) run metadata.
    private var queued: [QueueEntry] = []

    /// Per-running-run task handles. Stored so `cancel(_:)` can cancel the Task
    /// (which triggers the runner's `onTermination` handler via AsyncStream
    /// cooperative cancellation).
    private var runningTasks: [SummaryRunID: Task<Void, Never>] = [:]

    /// Runner factory. Production uses `PreReviewSummaryRunner.summarize(...)`.
    /// Tests inject a substitute factory.
    private let runnerFactory: RunnerFactory

    /// Store used for cache lookups and persistence. Set via `configure(context:)`.
    private var liveStore: PreReviewSummaryStore?

    // MARK: - Types

    /// Full set of arguments needed to (re-)dispatch a run after it leaves the
    /// queue. Stored alongside the run ID so a queued entry is self-contained.
    private struct QueueEntry {
        let id: SummaryRunID
        let repo: String
        let prNumber: Int
        let prKey: String
        let headSha: String
    }

    /// Closure type for the runner factory. Matches `PreReviewSummaryRunner.summarize`
    /// so the test double only needs to replace the factory.
    typealias RunnerFactory = @Sendable (String, Int, String) -> AsyncStream<SummaryEvent>

    // MARK: - Init

    /// Primary init: inject the runner factory and an optional initial store.
    /// Tests pass a pre-configured store directly.
    init(
        runnerFactory: @escaping RunnerFactory,
        store: PreReviewSummaryStore?
    ) {
        self.runnerFactory = runnerFactory
        self.liveStore = store
    }

    /// Convenience init for tests that provide a store directly.
    convenience init(
        runnerFactory: @escaping RunnerFactory,
        storeContext: ModelContext
    ) {
        self.init(runnerFactory: runnerFactory, store: PreReviewSummaryStore(context: storeContext))
    }

    // MARK: - Public API

    /// Begin a summary run for `(repo, prNumber, prKey, headSha)`.
    ///
    /// Returns a `SummaryRunID`. The caller should observe `state(id)` to track
    /// progress. If a cached row already exists for `(prKey, headSha)`, the
    /// returned ID's state is immediately `.cached(display)` and no runner is
    /// invoked.
    @discardableResult
    func start(
        repo: String,
        prNumber: Int,
        prKey: String,
        headSha: String
    ) -> SummaryRunID {
        let id = UUID()

        // 1. Cache hit short-circuit.
        if let cached = liveStore?.existing(prKey: prKey, headSha: headSha) {
            let display = PreReviewSummaryDisplay(
                what: cached.what,
                why: cached.why,
                risk: cached.risk
            )
            states[id] = .cached(display)
            return id
        }

        // 2. Under cap → run immediately; otherwise queue.
        let cap = AppSettings.summaryConcurrencyCap
        let entry = QueueEntry(
            id: id,
            repo: repo,
            prNumber: prNumber,
            prKey: prKey,
            headSha: headSha
        )

        if runningIDs.count < cap {
            runningIDs.append(id)
            states[id] = .running
            dispatch(entry: entry)
        } else {
            queued.append(entry)
            states[id] = .queued(ahead: queued.count - 1)
        }

        return id
    }

    /// Cancel a queued or running summary. Idempotent.
    ///
    /// - Queued: removes from the queue. The ID is removed from `states` (terminal).
    /// - Running: cancels the underlying Task. The runner's `onTermination`
    ///   handler SIGTERMs the process. The ID is removed from `states`.
    func cancel(_ id: SummaryRunID) {
        // Remove from queue if present.
        if let idx = queued.firstIndex(where: { $0.id == id }) {
            queued.remove(at: idx)
            states[id] = nil
            rebuildQueuedAheadCounts()
            return
        }

        // Cancel the running task if present.
        if let task = runningTasks[id] {
            task.cancel()
            runningTasks[id] = nil
            runningIDs.removeAll { $0 == id }
            states[id] = nil
            drainQueue()
        }
    }

    /// Current state for `id`. Returns `.idle` when the ID is unknown (not
    /// started, or already terminal and cleaned up).
    func state(_ id: SummaryRunID) -> SummaryRunState {
        states[id] ?? .idle
    }

    /// Publish a `.failed` state for a synthetic ID without enqueuing a run.
    /// Used by callers to surface pre-flight errors (e.g. SHA-fetch failure)
    /// through the same `states` map so the card shows the retry button.
    @discardableResult
    func synthesizeFailure(message: String) -> SummaryRunID {
        let id = UUID()
        states[id] = .failed(message: message)
        return id
    }

    /// An `AsyncStream<SummaryEvent>` for `id`. For a cache-hit ID this stream
    /// emits one synthetic `.result` event then finishes immediately. For all
    /// other IDs the stream yields nothing and finishes immediately — callers
    /// should prefer observing `states` directly via `@ObservedObject`.
    func events(_ id: SummaryRunID) -> AsyncStream<SummaryEvent> {
        switch states[id] {
        case .cached(let display):
            return AsyncStream { continuation in
                continuation.yield(.result(what: display.what, why: display.why, risk: display.risk))
                continuation.finish()
            }
        default:
            return AsyncStream { continuation in
                continuation.finish()
            }
        }
    }

    // MARK: - Queue management

    /// Promote queued entries to running until the cap is reached or the queue
    /// is empty.
    private func drainQueue() {
        let cap = AppSettings.summaryConcurrencyCap
        while runningIDs.count < cap, !queued.isEmpty {
            let entry = queued.removeFirst()
            runningIDs.append(entry.id)
            states[entry.id] = .running
            dispatch(entry: entry)
        }
        rebuildQueuedAheadCounts()
    }

    /// Recompute `.queued(ahead:)` for every entry still in the queue after a
    /// removal (cancel or drain).
    private func rebuildQueuedAheadCounts() {
        for (index, entry) in queued.enumerated() {
            states[entry.id] = .queued(ahead: index)
        }
    }

    // MARK: - Dispatch

    /// Kick off a Task that consumes the runner stream for `entry`.
    private func dispatch(entry: QueueEntry) {
        let id = entry.id
        let stream = runnerFactory(entry.repo, entry.prNumber, entry.headSha)
        let prKey = entry.prKey
        let headSha = entry.headSha

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.consumeStream(stream, id: id, prKey: prKey, headSha: headSha)
            self.finishRunning(id: id)
        }
        runningTasks[id] = task
    }

    /// Consume the runner's `AsyncStream<SummaryEvent>` and update state.
    private func consumeStream(
        _ stream: AsyncStream<SummaryEvent>,
        id: SummaryRunID,
        prKey: String,
        headSha: String
    ) async {
        var sawTerminal = false

        for await event in stream {
            // If the id is no longer in the running set, `cancel(_:)` was called.
            // Bail out without overwriting the (now-nil) state.
            if !runningIDs.contains(id) { return }

            switch event {
            case .delta:
                // Streaming preview: no per-delta state update. The card shows
                // a spinner while `.running`.
                break

            case .result(let what, let why, let risk):
                if let store = liveStore {
                    let summary = PreReviewSummary(
                        prKey: prKey,
                        headSha: headSha,
                        what: what,
                        why: why,
                        risk: risk,
                        generatedAt: Date()
                    )
                    store.save(summary)
                }
                let display = PreReviewSummaryDisplay(what: what, why: why, risk: risk)
                states[id] = .cached(display)
                sawTerminal = true

            case .error(let message):
                states[id] = .failed(message: message)
                sawTerminal = true
            }

            if sawTerminal { return }
        }

        // Stream finished without a terminal event (process exited cleanly but
        // emitted no `.result` or `.error`). Only surface failure if the id
        // is still in the running set (i.e. not cancelled).
        if !sawTerminal, runningIDs.contains(id) {
            states[id] = .failed(message: "claude exited without producing a summary.")
        }
    }

    /// Remove `id` from the running set and drain the queue.
    private func finishRunning(id: SummaryRunID) {
        runningIDs.removeAll { $0 == id }
        runningTasks[id] = nil
        drainQueue()
    }
}
