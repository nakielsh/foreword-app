//
//  ReviewOrchestrator.swift
//  WorkHomepage
//
//  Slice 13 — Concurrency cap + queue + cancellation.
//
//  Replaces slice 07's single-flight gate with a real concurrency model:
//
//    queued -> running -> (completed | cancelled | failed | timeout)
//
//  Behaviour:
//   - `start(...)` looks at `running.count` against `AppSettings.concurrencyCap`.
//     Under cap → the review enters `running` and gets dispatched immediately.
//     At/over cap → the review enters `queued` and waits in FIFO order.
//   - `cancel(_:)` on a `queued` review removes it from the queue, marks it
//     `cancelled`, and never spawns the pipeline.
//   - `cancel(_:)` on a `running` review SIGTERMs the pipeline (SIGKILL after
//     2s if the child is still alive), drops the partial stream from
//     persistence (state flips to `cancelled` rather than `completed`), and
//     keeps the worktree on disk for fast re-review (slice 13 acceptance
//     criteria: "Worktree is preserved after cancellation.").
//   - When any running review reaches a terminal state, the queue drains:
//     the next FIFO `queued` review transitions to `running` and the pipeline
//     is dispatched.
//   - The cap is read at decision time. Reducing the cap mid-flight does not
//     kill running reviews; existing runs finish normally and only new starts
//     see the new cap.
//
//  `current` semantics are preserved from slice 07-fix: it points at the
//  most recently started review. The toolbar pill (SidebarView) and the
//  modal sheet (ReviewSheet) bind to `current`. Closing the pill via X is
//  refused while `current?.state == "running"` so the user can't lose the
//  UI handle to a live process.
//
//  ## Process tracking
//
//  `Process` objects spawned via `ClaudeRunner` are tracked in
//  `runningProcesses[review.id]`. On cancel, we look up the box and signal
//  it (SIGTERM, then SIGKILL on a 2s grace timer). The pipeline closure
//  also receives a `CancellationContext` so injected (test) pipelines can
//  observe cancellation cooperatively without spawning a real process.
//
//  ## Testability
//
//  The pipeline body is parameterised. Production calls into `runRealPipeline`
//  which wires the slice-07 + slice-10 stages (worktree → Jira → claude →
//  persist). Tests inject a `pipeline:` closure that simulates whatever
//  state machine they want to exercise; no real process is spawned.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ReviewOrchestrator {

    /// Process-wide singleton. The Review buttons, modal sheet, and toolbar
    /// pill all bind to this instance.
    static let shared = ReviewOrchestrator()

    // MARK: - Public observable state

    /// Reviews currently in `running` state. FIFO start order, but order in
    /// the array is *not* a guarantee — callers should treat this as a set
    /// for membership/count queries.
    private(set) var running: [Review] = []

    /// Reviews waiting to start, FIFO. `queued[0]` is next to drain. Position
    /// in this array drives the per-card "Queued (N ahead)" label.
    private(set) var queued: [Review] = []

    /// The review the modal sheet is "focused" on. Set to the most recently
    /// started review (slice 07-fix invariant). Survives the run reaching a
    /// terminal state so the user can read the result; cleared by
    /// `clearCurrent()` once not running.
    var current: Review?

    /// Last user-visible error not tied to a specific Review row. Cleared on
    /// each new `start(...)`.
    var lastRejection: String?

    /// Number of reviews under orchestrator control (running + queued).
    /// Drives the toolbar in-flight indicator's visibility.
    var inFlightCount: Int { running.count + queued.count }

    /// True iff at least one review is in `running` state. Kept for backward
    /// compatibility with slice-07 callers (toolbar pill X-button guard,
    /// WorktreeManager's eviction guard, MenuBarCounts).
    var isRunning: Bool { !running.isEmpty }

    // MARK: - Internal state

    /// Per-running-review handles: live `Process` (if any) + the in-flight
    /// pipeline `Task`. Cancellation looks up the entry by `Review.id` and
    /// signals both. The dict is the source of truth for "is this review
    /// actively cancellable?".
    @ObservationIgnored
    private var runningHandles: [UUID: RunningHandle] = [:]

    /// Cancellation flag bag. Injected pipelines read this via
    /// `CancellationContext.isCancelled`. Production's `runRealPipeline`
    /// also consults it so the post-process pipeline doesn't continue
    /// persisting a cancelled stream.
    @ObservationIgnored
    private var cancellationFlags: [UUID: CancellationFlag] = [:]

    /// Per-review pipeline metadata kept alive while the review is queued or
    /// running. Holds the `ReviewStore` and the routing fields so a queued
    /// review can be promoted to running without the caller re-supplying
    /// them.
    @ObservationIgnored
    private var pendingMeta: [UUID: PendingMeta] = [:]

    /// Default pipeline used in production. Wired in `init`. Tests construct
    /// a fresh orchestrator (or call the test seam on `start`) to inject
    /// their own.
    @ObservationIgnored
    private let defaultPipeline: @MainActor (PipelineInput) async -> Void

    // MARK: - Init

    /// Production callers use the singleton. Tests can construct their own
    /// instance with a stubbed pipeline. The default pipeline closure is the
    /// real slice-07 + slice-10 body extracted into `runRealPipeline`.
    init() {
        self.defaultPipeline = { input in
            await ReviewOrchestrator.runRealPipeline(input: input)
        }
    }

    /// Test-only initialiser: every `start(...)` call routes through `pipeline`
    /// instead of the real claude/worktree wiring. The closure is responsible
    /// for any state mutation (persistence, terminal-state marking) it wants
    /// the orchestrator to react to — the orchestrator itself only manages
    /// queue + running + current bookkeeping.
    init(pipeline: @escaping @MainActor (PipelineInput) async -> Void) {
        self.defaultPipeline = pipeline
    }

    // MARK: - Public API

    /// Kick off a review for `(repo, prNumber, branch, sha)`. Returns the
    /// freshly-inserted `Review` row. The row's state is `queued` if we
    /// were already at cap when the call landed, `running` otherwise.
    @discardableResult
    func start(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        store: ReviewStore
    ) async -> Review {
        lastRejection = nil

        let prKey = "\(repo)#\(prNumber)"
        let cap = AppSettings.concurrencyCap

        // Insert the row; we override the default `running` state from
        // ReviewStore.addReview when we need to queue.
        let review = store.addReview(
            prKey: prKey,
            repoFullName: repo,
            prNumber: prNumber,
            headSha: sha,
            headBranch: branch
        )
        current = review

        // Stash the meta so a queued review (or a freshly-started running
        // one) can be promoted later without the caller threading the args
        // back in.
        pendingMeta[review.id] = PendingMeta(
            repo: repo,
            prNumber: prNumber,
            branch: branch,
            sha: sha,
            store: store
        )

        if running.count < cap {
            // Under cap — dispatch immediately. `addReview` already set state
            // to `running` and persisted, so we just kick the pipeline.
            running.append(review)
            dispatchPipeline(review: review)
        } else {
            // At/over cap — flip to `queued` and park.
            review.state = "queued"
            try? store.context.save()
            queued.append(review)
        }

        return review
    }

    /// Cancel a queued or running review. Idempotent: cancelling a review
    /// already in a terminal state is a no-op.
    func cancel(_ review: Review) {
        switch review.state {
        case "queued":
            // Pull from the queue without ever touching a process.
            queued.removeAll { $0.id == review.id }
            review.state = "cancelled"
            review.finishedAt = Date()
            review.errorMessage = "Cancelled before start."
            try? pendingMeta[review.id]?.store.context.save()
            pendingMeta[review.id] = nil

        case "running":
            // Mark the cancellation flag first so a cooperative pipeline
            // sees it on its next checkpoint.
            cancellationFlags[review.id]?.cancel()

            // Signal the underlying process if there is one. SIGTERM, then
            // SIGKILL after a 2-second grace if it's still alive. The
            // closure captures the box (a class) weakly so we don't keep
            // the entry alive past `finishRunning`.
            if let handle = runningHandles[review.id] {
                handle.task.cancel()
                if let pid = handle.processBox.pid {
                    kill(pid, SIGTERM)
                    let box = handle.processBox
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak box] in
                        if let pid = box?.pid, box?.isRunning == true {
                            kill(pid, SIGKILL)
                        }
                    }
                }
            }

            // Flip state. The pipeline body will see `cancellation.isCancelled`
            // on its next checkpoint and bail without persisting findings.
            review.state = "cancelled"
            review.finishedAt = Date()
            review.errorMessage = "Cancelled by user."
            try? pendingMeta[review.id]?.store.context.save()

            // Drop from the running set and drain the queue. The pipeline
            // task will still complete async, but `running` reflects the
            // user-visible state machine immediately.
            running.removeAll { $0.id == review.id }
            runningHandles[review.id] = nil
            cancellationFlags[review.id] = nil
            pendingMeta[review.id] = nil
            drainQueue()

        default:
            // Already in a terminal state. Nothing to cancel.
            break
        }
    }

    /// Clear `current`. Refuses while the current review is still running so
    /// the user can't accidentally lose the UI handle to a live process.
    func clearCurrent() {
        if let cur = current, cur.state == "running" { return }
        current = nil
        lastRejection = nil
    }

    // MARK: - Queue draining

    /// Called whenever a `running` review reaches a terminal state. Walks the
    /// FIFO queue and promotes the head to `running` until either the queue
    /// is empty or we hit the cap. Each promotion dispatches its pipeline.
    private func drainQueue() {
        let cap = AppSettings.concurrencyCap
        while running.count < cap, !queued.isEmpty {
            let next = queued.removeFirst()
            // Skip rows that were cancelled out from under us.
            if next.state != "queued" { continue }
            guard let meta = pendingMeta[next.id] else { continue }
            next.state = "running"
            try? meta.store.context.save()
            running.append(next)
            dispatchPipeline(review: next)
            _ = meta // silence unused warning when running == queue
        }
    }

    // MARK: - Pipeline dispatch

    /// Wraps the pipeline in a Task and tracks its handle so `cancel(_:)`
    /// can reach it. On task completion, the orchestrator removes the entry
    /// from `running`, clears the handle, and drains the queue.
    private func dispatchPipeline(review: Review) {
        guard let meta = pendingMeta[review.id] else { return }
        let processBox = ProcessBox()
        let cancelFlag = CancellationFlag()
        cancellationFlags[review.id] = cancelFlag

        let input = PipelineInput(
            review: review,
            repo: meta.repo,
            prNumber: meta.prNumber,
            branch: meta.branch,
            sha: meta.sha,
            store: meta.store,
            processBox: processBox,
            cancellation: CancellationContext(flag: cancelFlag)
        )

        let pipeline = defaultPipeline
        let task = Task { @MainActor [weak self] in
            await pipeline(input)
            // Post-pipeline housekeeping. Done on the same actor so we can
            // mutate observable state without hopping.
            self?.finishRunning(review: review)
        }

        runningHandles[review.id] = RunningHandle(
            processBox: processBox,
            task: task
        )
    }

    /// Move `review` out of the `running` set. Idempotent — if the review was
    /// already removed (e.g. by `cancel`), this is a no-op for the data
    /// structures, but it still triggers a queue drain.
    private func finishRunning(review: Review) {
        running.removeAll { $0.id == review.id }
        runningHandles[review.id] = nil
        cancellationFlags[review.id] = nil
        pendingMeta[review.id] = nil
        drainQueue()
    }

    // MARK: - Real pipeline (production)

    /// The slice 07 + slice 10 body, extracted as a static so the `init`
    /// default closure can capture it without holding a self reference.
    /// The orchestrator passes one `PipelineInput` per invocation; this
    /// function does NOT manage `running`/`queued` membership — that's the
    /// orchestrator's job.
    @MainActor
    private static func runRealPipeline(input: PipelineInput) async {
        let review = input.review
        let store = input.store

        // Step 1: prepare the worktree.
        let worktreeURL: URL
        do {
            worktreeURL = try await WorktreeManager.prepare(
                repo: input.repo,
                branch: input.branch,
                sha: input.sha,
                prNumber: input.prNumber
            )
        } catch {
            if input.cancellation.isCancelled { return }
            store.markFailed(review, error: "Worktree prep failed: \(error)")
            return
        }

        if input.cancellation.isCancelled { return }

        // Step 2: resolve Jira context (slice 10).
        let jiraKey = TicketKeyExtractor.extract(branchName: input.branch)
        if let jiraKey {
            review.jiraKey = jiraKey
            try? store.context.save()
        }

        let jiraTicket = await fetchJiraTicket(key: jiraKey)
        if input.cancellation.isCancelled { return }

        // Step 3: build the prompt.
        let prompt = OrchestratorPrompt.build(
            repo: input.repo,
            prNumber: input.prNumber,
            branch: input.branch,
            sha: input.sha,
            jira: jiraTicket
        )

        // Step 4: spawn `claude` and consume the stream.
        let stream: AsyncThrowingStream<ClaudeEvent, Error>
        do {
            stream = try ClaudeRunner.run(
                prompt: prompt,
                schema: Constants.reviewJSONSchema,
                cwd: worktreeURL,
                allowedTools: "Read,Grep,Glob,Bash(gh:*),Bash(git:*)"
            )
        } catch ClaudeRunnerError.binaryNotFound {
            if input.cancellation.isCancelled { return }
            store.markFailed(review, error: "`claude` binary not found. Configure it in Settings.")
            return
        } catch {
            if input.cancellation.isCancelled { return }
            store.markFailed(review, error: "Failed to launch claude: \(error)")
            return
        }

        var sawTerminalEvent = false
        var lastError: String?

        do {
            for try await event in stream {
                if input.cancellation.isCancelled {
                    // Drop the rest of the stream; the orchestrator already
                    // SIGTERM'd the child. Don't persist anything further.
                    return
                }
                switch event {
                case .textDelta(let text):
                    store.appendStream(review, text: text)
                case .toolUse(let name):
                    store.appendStream(review, text: "\n[tool: \(name)]\n")
                case .finalResult(let rawJSON, let decoded):
                    if input.cancellation.isCancelled { return }
                    store.markCompleted(review, schema: decoded, rawJSON: rawJSON)
                    sawTerminalEvent = true
                case .error(let message):
                    lastError = message
                    sawTerminalEvent = true
                }
            }
        } catch {
            lastError = "Stream error: \(error)"
        }

        if input.cancellation.isCancelled { return }

        // Step 5: terminal-state housekeeping.
        if review.state != "completed" {
            if let lastError, lastError == "timeout" {
                store.markTimeout(review)
            } else if let lastError {
                store.markFailed(review, error: lastError)
            } else if !sawTerminalEvent {
                store.markFailed(review, error: "claude exited without producing a result.")
            } else {
                store.markFailed(review, error: "Unknown terminal state.")
            }
        }
    }

    // MARK: - Jira

    /// Fetch the Jira ticket for `key` if both a key and credentials are
    /// available. Returns nil for the (common) "no Jira" cases.
    private static func fetchJiraTicket(key: String?) async -> JiraTicket? {
        guard let key else { return nil }
        do {
            return try await JiraClient().fetchTicket(key: key)
        } catch JiraClient.JiraError.notConfigured {
            NSLog("[ReviewOrchestrator] Jira not configured — proceeding without Jira context.")
            return nil
        } catch JiraClient.JiraError.unauthorized {
            NSLog("[ReviewOrchestrator] Jira returned 401 for \(key) — proceeding without Jira context.")
            return nil
        } catch JiraClient.JiraError.ticketNotFound {
            NSLog("[ReviewOrchestrator] Jira ticket \(key) not found — proceeding without Jira context.")
            return nil
        } catch JiraClient.JiraError.http(let status, _) {
            NSLog("[ReviewOrchestrator] Jira fetch for \(key) failed with HTTP \(status) — proceeding without Jira context.")
            return nil
        } catch {
            NSLog("[ReviewOrchestrator] Jira fetch for \(key) errored: \(error) — proceeding without Jira context.")
            return nil
        }
    }

    // MARK: - Prompt shim

    /// Compatibility shim for callers (and tests) that referenced the legacy
    /// slice 07 prompt builder. New code should call `OrchestratorPrompt.build`
    /// directly.
    nonisolated static func buildPrompt(repo: String, prNumber: Int, branch: String, sha: String) -> String {
        OrchestratorPrompt.build(
            repo: repo,
            prNumber: prNumber,
            branch: branch,
            sha: sha,
            jira: nil
        )
    }
}

// MARK: - Pipeline plumbing types

/// Inputs handed to a pipeline closure. Production reads `repo/prNumber/...`
/// to do the real work; tests typically only need `review`, `store`, and
/// `cancellation` to simulate state transitions.
struct PipelineInput {
    let review: Review
    let repo: String
    let prNumber: Int
    let branch: String
    let sha: String
    let store: ReviewStore
    let processBox: ProcessBox
    let cancellation: CancellationContext
}

/// Cooperative cancellation hook for injected pipelines. The orchestrator
/// flips the underlying flag from `cancel(_:)` and the pipeline observes it
/// at whatever granularity it cares to.
struct CancellationContext {
    fileprivate let flag: CancellationFlag
    var isCancelled: Bool { flag.isCancelled }
    /// Throws `CancellationError` if cancelled. Mirrors `Task.checkCancellation`.
    func checkCancellation() throws {
        if flag.isCancelled { throw CancellationError() }
    }
}

/// Backing flag for `CancellationContext`. Reference type so multiple readers
/// see the same state.
final class CancellationFlag {
    private(set) var isCancelled: Bool = false
    func cancel() { isCancelled = true }
}

/// A thread-safe-ish box around a live `Process`'s pid. The runner that
/// actually owns the `Process` is `ClaudeRunner`; the orchestrator only
/// cares about the pid for SIGTERM/SIGKILL. Production never sets this from
/// outside `ClaudeRunner` because that runner has its own internal box and
/// signals on its own. Slice 13 keeps this here for forward compatibility:
/// once `ClaudeRunner` exposes a way to publish its pid to us, we can target
/// it directly. For now the orchestrator's cancel of a running review goes
/// via the AsyncStream's `onTermination` (cooperative), and SIGTERM-via-pid
/// is exercised when the test pipeline opts in.
final class ProcessBox {
    private(set) var pid: pid_t?
    private(set) var isRunning: Bool = false

    func attach(pid: pid_t) {
        self.pid = pid
        self.isRunning = true
    }

    func markExited() {
        isRunning = false
    }
}

/// Per-running-review handles. The task lets us cancel cooperatively via
/// `Task.cancel()`; the process box lets us kill the underlying child if
/// `ClaudeRunner` published its pid.
private struct RunningHandle {
    let processBox: ProcessBox
    let task: Task<Void, Never>
}

/// Routing fields stashed at `start` time so the queue drainer can promote
/// a queued review to running without the caller threading the same args
/// back in. Holds the `ReviewStore` so the orchestrator can save state
/// transitions through the same context the row was inserted on.
private struct PendingMeta {
    let repo: String
    let prNumber: Int
    let branch: String
    let sha: String
    let store: ReviewStore
}
