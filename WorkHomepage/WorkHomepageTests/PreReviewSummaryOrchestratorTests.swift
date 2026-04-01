//
//  PreReviewSummaryOrchestratorTests.swift
//  WorkHomepageTests
//
//  Slice 25 — concurrency cap, queue, cancellation, cache hit, retry.
//
//  Drives a `PreReviewSummaryOrchestrator` with an injected runner factory so
//  we never spawn a real `claude` process. The factory hands back per-run
//  `AsyncStream<SummaryEvent>`s whose continuations are held by a `Gate` that
//  the test controls, mirroring the pattern in `ReviewOrchestratorConcurrencyTests`.
//
//  Contract tested:
//   - Cache hit short-circuits (runner factory never invoked).
//   - Cap=2: first two runs enter `.running`, third is `.queued(ahead: 0)`.
//   - Completing a running run promotes the queued one.
//   - Cancel queued: run never enters running, runner factory never invoked.
//   - Cancel running: state becomes nil (terminal); subsequent drain promotes next.
//   - Failure → retry → success path.
//   - `events(id)` stream for a cache-hit ID yields one synthetic `.result` then closes.
//

import XCTest
import SwiftData
@testable import WorkHomepage

@MainActor
final class PreReviewSummaryOrchestratorTests: XCTestCase {

    // MARK: - Fixtures

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([PreReviewSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private var savedCap: Int = AppSettings.summaryConcurrencyCapDefault

    override func setUp() {
        super.setUp()
        savedCap = AppSettings.summaryConcurrencyCap
    }

    override func tearDown() {
        AppSettings.summaryConcurrencyCap = savedCap
        super.tearDown()
    }

    // MARK: - Gate

    /// One slot per active pipeline. Parks the stream until the test calls `release()`.
    private final class Gate: @unchecked Sendable {
        private var continuation: CheckedContinuation<Void, Never>?
        private var alreadyReleased = false
        private let lock = NSLock()

        func wait() async {
            await withCheckedContinuation { cont in
                lock.lock()
                defer { lock.unlock() }
                if alreadyReleased {
                    cont.resume()
                } else {
                    continuation = cont
                }
            }
        }

        func release() {
            let c: CheckedContinuation<Void, Never>?
            lock.lock()
            if let existing = continuation {
                continuation = nil
                c = existing
            } else {
                alreadyReleased = true
                c = nil
            }
            lock.unlock()
            c?.resume()
        }
    }

    /// What the fake runner emits after the gate is released.
    private enum RunOutcome: Sendable {
        case success(what: String, why: String, risk: String)
        case failure(message: String)
    }

    // MARK: - FakeRunnerState

    /// Shared mutable state for the fake runner factory. Uses `@unchecked Sendable`
    /// so the `@Sendable` factory closure can capture it — all access to this
    /// object in tests happens on the `@MainActor` TestCase, and all access from
    /// the factory closure hops to MainActor via Task. The lock is a safety belt.
    private final class FakeRunnerState: @unchecked Sendable {
        var startedCount: Int = 0
        var pendingOutcomes: [RunOutcome] = []
        var gates: [Int: Gate] = [:]
        let lock = NSLock()

        func nextOutcome() -> RunOutcome {
            lock.lock()
            defer { lock.unlock() }
            if pendingOutcomes.isEmpty {
                return .success(what: "w", why: "y", risk: "r")
            }
            return pendingOutcomes.removeFirst()
        }

        func registerGate(index: Int, gate: Gate) {
            lock.lock()
            defer { lock.unlock() }
            gates[index] = gate
        }

        func incrementAndReturnIndex() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let idx = startedCount
            startedCount += 1
            return idx
        }
    }

    // MARK: - FakeRunnerFactory

    /// Test-double factory. Holds a `FakeRunnerState` that the `@Sendable` closure
    /// can capture. Gate creation and outcome selection happen synchronously in the
    /// closure (protected by a lock inside FakeRunnerState) so the returned stream
    /// is immediately usable.
    @MainActor
    private final class FakeRunnerFactory {
        let state = FakeRunnerState()

        var startedCount: Int { state.startedCount }

        func enqueue(_ outcomes: RunOutcome...) {
            state.lock.lock()
            defer { state.lock.unlock() }
            state.pendingOutcomes.append(contentsOf: outcomes)
        }

        /// The factory closure handed to the orchestrator. Must be `@Sendable`.
        var factory: PreReviewSummaryOrchestrator.RunnerFactory {
            let s = state
            return { _, _, _ -> AsyncStream<SummaryEvent> in
                let index = s.incrementAndReturnIndex()
                let gate = Gate()
                s.registerGate(index: index, gate: gate)
                let outcome = s.nextOutcome()

                return AsyncStream { continuation in
                    Task {
                        await gate.wait()
                        switch outcome {
                        case .success(let w, let y, let r):
                            continuation.yield(.result(what: w, why: y, risk: r))
                        case .failure(let msg):
                            continuation.yield(.error(message: msg))
                        }
                        continuation.finish()
                    }
                }
            }
        }

        /// Release gate for invocation at `index`.
        func release(index: Int) {
            state.lock.lock()
            let gate = state.gates[index]
            state.lock.unlock()
            gate?.release()
        }

        /// Polling helper: spin until `startedCount >= expected`.
        func waitUntilStarted(count expected: Int, timeoutSeconds: Double = 2.0) async {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while state.startedCount < expected {
                if Date() > deadline { return }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }

    // MARK: - Helpers

    private func makeOrchestrator(
        factory: FakeRunnerFactory,
        context: ModelContext
    ) -> PreReviewSummaryOrchestrator {
        PreReviewSummaryOrchestrator(
            runnerFactory: factory.factory,
            storeContext: context
        )
    }

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

    // MARK: - Cache hit short-circuit

    func testCacheHitShortCircuitsWithoutInvokingRunner() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)
        let fake = FakeRunnerFactory()

        let summary = PreReviewSummary(
            prKey: "org/repo#1",
            headSha: "abc123",
            what: "Added feature",
            why: "User story",
            risk: "Low risk",
            generatedAt: Date()
        )
        store.save(summary)

        let orch = makeOrchestrator(factory: fake, context: context)
        let id = orch.start(repo: "org/repo", prNumber: 1, prKey: "org/repo#1", headSha: "abc123")

        if case .cached(let display) = orch.state(id) {
            XCTAssertEqual(display.what, "Added feature")
            XCTAssertEqual(display.why, "User story")
            XCTAssertEqual(display.risk, "Low risk")
        } else {
            XCTFail("Expected .cached state, got \(orch.state(id))")
        }
        XCTAssertEqual(fake.startedCount, 0)
    }

    func testCacheHitEventsStreamYieldsResultThenCloses() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let store = PreReviewSummaryStore(context: context)
        let fake = FakeRunnerFactory()

        let summary = PreReviewSummary(
            prKey: "org/repo#2",
            headSha: "def456",
            what: "W",
            why: "Y",
            risk: "R",
            generatedAt: Date()
        )
        store.save(summary)

        let orch = makeOrchestrator(factory: fake, context: context)
        let id = orch.start(repo: "org/repo", prNumber: 2, prKey: "org/repo#2", headSha: "def456")

        var received: [SummaryEvent] = []
        for await event in orch.events(id) {
            received.append(event)
        }

        XCTAssertEqual(received.count, 1)
        if case .result(let w, let y, let r) = received[0] {
            XCTAssertEqual(w, "W")
            XCTAssertEqual(y, "Y")
            XCTAssertEqual(r, "R")
        } else {
            XCTFail("Expected .result event")
        }
    }

    // MARK: - Concurrency cap

    func testConcurrencyCapQueuesExcessRuns() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        let id2 = orch.start(repo: "r", prNumber: 2, prKey: "r#2", headSha: "s2")
        let id3 = orch.start(repo: "r", prNumber: 3, prKey: "r#3", headSha: "s3")

        XCTAssertEqual(orch.state(id1), .running)
        XCTAssertEqual(orch.state(id2), .running)
        XCTAssertEqual(orch.state(id3), .queued(ahead: 0))

        await fake.waitUntilStarted(count: 2)
        fake.release(index: 0)
        await pollUntil { orch.state(id3) == .running }
        XCTAssertEqual(orch.state(id3), .running)

        // Drain.
        fake.release(index: 1)
        await fake.waitUntilStarted(count: 3)
        fake.release(index: 2)
        await pollUntil {
            self.allTerminal(orch, ids: [id1, id2, id3])
        }
    }

    func testQueueAheadCountsCorrect() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        let id2 = orch.start(repo: "r", prNumber: 2, prKey: "r#2", headSha: "s2")
        let id3 = orch.start(repo: "r", prNumber: 3, prKey: "r#3", headSha: "s3")
        let id4 = orch.start(repo: "r", prNumber: 4, prKey: "r#4", headSha: "s4")

        XCTAssertEqual(orch.state(id1), .running)
        XCTAssertEqual(orch.state(id2), .running)
        XCTAssertEqual(orch.state(id3), .queued(ahead: 0))
        XCTAssertEqual(orch.state(id4), .queued(ahead: 1))

        await fake.waitUntilStarted(count: 2)
        for i in 0..<4 { fake.release(index: i) }
        await pollUntil { self.allTerminal(orch, ids: [id1, id2, id3, id4]) }
    }

    // MARK: - Cancel queued

    func testCancelQueuedNeverInvokesRunner() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        let id2 = orch.start(repo: "r", prNumber: 2, prKey: "r#2", headSha: "s2")
        let id3 = orch.start(repo: "r", prNumber: 3, prKey: "r#3", headSha: "s3")

        XCTAssertEqual(orch.state(id3), .queued(ahead: 0))
        orch.cancel(id3)
        XCTAssertEqual(orch.state(id3), .idle)

        await fake.waitUntilStarted(count: 2)
        fake.release(index: 0)
        fake.release(index: 1)
        await pollUntil { self.allTerminal(orch, ids: [id1, id2]) }

        // Runner invoked exactly twice — id3 never ran.
        XCTAssertEqual(fake.startedCount, 2)
    }

    func testCancelQueuedRebuildsAheadCounts() async throws {
        AppSettings.summaryConcurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        let id2 = orch.start(repo: "r", prNumber: 2, prKey: "r#2", headSha: "s2")
        let id3 = orch.start(repo: "r", prNumber: 3, prKey: "r#3", headSha: "s3")

        XCTAssertEqual(orch.state(id2), .queued(ahead: 0))
        XCTAssertEqual(orch.state(id3), .queued(ahead: 1))

        orch.cancel(id2)
        XCTAssertEqual(orch.state(id2), .idle)
        XCTAssertEqual(orch.state(id3), .queued(ahead: 0))

        await fake.waitUntilStarted(count: 1)
        fake.release(index: 0)
        await pollUntil { orch.state(id3) == .running }
        await fake.waitUntilStarted(count: 2)
        fake.release(index: 1)
        await pollUntil { self.allTerminal(orch, ids: [id1, id3]) }
    }

    // MARK: - Cancel running

    func testCancelRunningTerminatesAndDrainsQueue() async throws {
        AppSettings.summaryConcurrencyCap = 1
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        let id2 = orch.start(repo: "r", prNumber: 2, prKey: "r#2", headSha: "s2")

        XCTAssertEqual(orch.state(id1), .running)
        XCTAssertEqual(orch.state(id2), .queued(ahead: 0))

        await fake.waitUntilStarted(count: 1)
        orch.cancel(id1)
        XCTAssertEqual(orch.state(id1), .idle)
        await pollUntil { orch.state(id2) == .running }
        XCTAssertEqual(orch.state(id2), .running)

        await fake.waitUntilStarted(count: 2)
        fake.release(index: 1)
        await pollUntil { self.isTerminal(orch.state(id2)) }
    }

    // MARK: - Failure → retry → success

    func testFailureRetrySuccess() async throws {
        AppSettings.summaryConcurrencyCap = 2
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        fake.enqueue(.failure(message: "connection reset"), .success(what: "W", why: "Y", risk: "R"))

        let orch = makeOrchestrator(factory: fake, context: context)

        let id1 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        await fake.waitUntilStarted(count: 1)
        fake.release(index: 0)

        await pollUntil {
            if case .failed = orch.state(id1) { return true }
            return false
        }
        if case .failed(let msg) = orch.state(id1) {
            XCTAssertEqual(msg, "connection reset")
        } else {
            XCTFail("Expected .failed state")
        }

        // Retry: fresh ID, same PR params.
        let id2 = orch.start(repo: "r", prNumber: 1, prKey: "r#1", headSha: "s1")
        XCTAssertNotEqual(id1, id2)

        await fake.waitUntilStarted(count: 2)
        fake.release(index: 1)

        await pollUntil {
            if case .cached = orch.state(id2) { return true }
            return false
        }
        if case .cached(let display) = orch.state(id2) {
            XCTAssertEqual(display.what, "W")
            XCTAssertEqual(display.why, "Y")
            XCTAssertEqual(display.risk, "R")
        } else {
            XCTFail("Expected .cached state after retry")
        }

        // Verify persistence.
        let store = PreReviewSummaryStore(context: context)
        let persisted = store.existing(prKey: "r#1", headSha: "s1")
        XCTAssertNotNil(persisted)
        XCTAssertEqual(persisted?.what, "W")
    }

    // MARK: - Cap = 3

    func testCapThreeRunsThreeAndQueuesRemainder() async throws {
        AppSettings.summaryConcurrencyCap = 3
        let container = try makeContainer()
        let context = ModelContext(container)
        let fake = FakeRunnerFactory()
        let orch = makeOrchestrator(factory: fake, context: context)

        var ids: [SummaryRunID] = []
        for n in 1...5 {
            ids.append(orch.start(repo: "r", prNumber: n, prKey: "r#\(n)", headSha: "s\(n)"))
        }

        XCTAssertEqual(orch.state(ids[0]), .running)
        XCTAssertEqual(orch.state(ids[1]), .running)
        XCTAssertEqual(orch.state(ids[2]), .running)
        XCTAssertEqual(orch.state(ids[3]), .queued(ahead: 0))
        XCTAssertEqual(orch.state(ids[4]), .queued(ahead: 1))

        await fake.waitUntilStarted(count: 3)
        fake.release(index: 0)
        await pollUntil { orch.state(ids[3]) == .running }
        XCTAssertEqual(orch.state(ids[3]), .running)
        XCTAssertEqual(orch.state(ids[4]), .queued(ahead: 0))

        for i in 1..<5 { fake.release(index: i) }
        await pollUntil { self.allTerminal(orch, ids: ids) }
    }

    // MARK: - AppSettings cap

    func testSummaryConcurrencyCapDefaultAndClamping() {
        XCTAssertEqual(AppSettings.summaryConcurrencyCapDefault, 5)
        XCTAssertEqual(AppSettings.clampSummaryCap(0), 1)
        XCTAssertEqual(AppSettings.clampSummaryCap(1), 1)
        XCTAssertEqual(AppSettings.clampSummaryCap(5), 5)
        XCTAssertEqual(AppSettings.clampSummaryCap(10), 10)
        XCTAssertEqual(AppSettings.clampSummaryCap(11), 10)
    }

    func testSummaryConcurrencyCapRoundTrip() {
        let defaults = UserDefaults(suiteName: "test.summaryCap.\(UUID().uuidString)")!
        AppSettings.setSummaryConcurrencyCap(7, defaults: defaults)
        XCTAssertEqual(AppSettings.summaryConcurrencyCap(defaults: defaults), 7)
        AppSettings.setSummaryConcurrencyCap(99, defaults: defaults)
        XCTAssertEqual(AppSettings.summaryConcurrencyCap(defaults: defaults), 10)
    }

    // MARK: - Private helpers

    private func isTerminal(_ state: SummaryRunState) -> Bool {
        switch state {
        case .cached, .failed, .idle: return true
        case .running, .queued: return false
        }
    }

    private func allTerminal(_ orch: PreReviewSummaryOrchestrator, ids: [SummaryRunID]) -> Bool {
        ids.allSatisfy { isTerminal(orch.state($0)) }
    }
}
