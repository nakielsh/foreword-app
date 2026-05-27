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
import os
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

    /// Concurrency-cap source. Production reads `AppSettings.concurrencyCap`
    /// at decision time. Tests inject a closure so they never have to mutate
    /// the shared `.standard` UserDefaults to drive the cap.
    @ObservationIgnored
    private let concurrencyCapProvider: @MainActor () -> Int

    // MARK: - Init

    /// Production callers use the singleton. Tests can construct their own
    /// instance with a stubbed pipeline. The default pipeline closure is the
    /// real slice-07 + slice-10 body extracted into `runRealPipeline`.
    init() {
        self.defaultPipeline = { input in
            await ReviewOrchestrator.runRealPipeline(input: input)
        }
        self.concurrencyCapProvider = { AppSettings.concurrencyCap }
    }

    /// Test-only initialiser: every `start(...)` call routes through `pipeline`
    /// instead of the real claude/worktree wiring. The closure is responsible
    /// for any state mutation (persistence, terminal-state marking) it wants
    /// the orchestrator to react to — the orchestrator itself only manages
    /// queue + running + current bookkeeping.
    init(pipeline: @escaping @MainActor (PipelineInput) async -> Void) {
        self.defaultPipeline = pipeline
        self.concurrencyCapProvider = { AppSettings.concurrencyCap }
    }

    /// Test-only initialiser with explicit pipeline + concurrency-cap injection.
    /// The cap closure is consulted at decision time (start / drainQueue), so
    /// tests can flip the cap mid-flight without mutating `AppSettings.standard`.
    init(
        pipeline: @escaping @MainActor (PipelineInput) async -> Void,
        concurrencyCap: @escaping @MainActor () -> Int
    ) {
        self.defaultPipeline = pipeline
        self.concurrencyCapProvider = concurrencyCap
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

        // Defence-in-depth: validate the repo + branch shape at the
        // orchestrator boundary before anything reaches `WorktreeManager`
        // (which would otherwise fold these into shell arguments). The
        // pipeline still spawns git through `Process` (no shell), so this is
        // not the only line of defence — but rejecting malformed input here
        // makes the failure visible to the user instead of hidden behind a
        // git stderr dump.
        do {
            try GitHubRepoSpec.validate(repo)
            try GitBranchSpec.validate(branch)
        } catch {
            lastRejection = "Refused to start review: \(error)"
            // Insert a row anyway so the user has a UI handle, but flip it
            // straight to `failed` and never reach the pipeline.
            let review = store.addReview(
                prKey: "\(repo)#\(prNumber)",
                repoFullName: repo,
                prNumber: prNumber,
                headSha: sha,
                headBranch: branch
            )
            store.markFailed(review, error: "\(error)")
            current = review
            return review
        }

        let prKey = "\(repo)#\(prNumber)"
        let cap = concurrencyCapProvider()

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
        let cap = concurrencyCapProvider()
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

        let jiraTicket = await Self.fetchJiraTicket(key: jiraKey, context: store.context)
        if input.cancellation.isCancelled { return }

        // Step 3: fetch the PR's changed-files list. Anchors the prompt's
        // allowlist block and gives the model a precise vocabulary of paths
        // it's allowed to cite. Failure is non-fatal — degrades to the
        // pre-allowlist behaviour rather than blocking the review.
        let changedFiles = await Self.fetchChangedFiles(
            repo: input.repo,
            prNumber: input.prNumber
        )

        if input.cancellation.isCancelled { return }

        // Step 4: build the prompt.
        //
        // Wrap user-supplied / upstream-supplied text (branch name, Jira
        // summary + description, parent description) in untrusted-content
        // fences before they reach the prompt builder. The fences are a
        // visible signal to the model that anything inside should be treated
        // as data — never as instructions to follow. Defence-in-depth on top
        // of `--allowed-tools` (read-only set + explicit denies for
        // Bash/Write/Edit, see ClaudeRunner call below).
        let safeBranch = UntrustedContent.fence(input.branch, label: "branch")
        let safeJira = jiraTicket.map { UntrustedContent.sanitise($0) }
        let prompt = OrchestratorPrompt.build(
            repo: input.repo,
            prNumber: input.prNumber,
            branch: safeBranch,
            sha: input.sha,
            jira: safeJira,
            changedFiles: changedFiles
        )

        // Step 4: spawn `claude` and consume the stream.
        //
        // Default tool surface is read-only: Read / Grep / Glob plus the two
        // narrow Bash sub-allows for `gh` and `git` we already had, with
        // explicit denials for `Bash` (general), `Write`, and `Edit`. The
        // narrow Bash allow-list above pins specific binaries; the `Bash`
        // deny line below is belt-and-suspenders against future regressions
        // where a wider Bash allow-list might be added.
        //
        // `Task` is denied: subagents have observed to hallucinate diffs
        // (e.g. returning a different PR's changes), and the main agent
        // then trusts that fabricated output over the authoritative
        // allowlist in the prompt. The review agent has direct access to
        // `gh` and `Read` — no need to dispatch a subagent.
        // `WebFetch` / `WebSearch` denied: review is local-only by design.
        let stream: AsyncThrowingStream<ClaudeEvent, Error>
        do {
            stream = try ClaudeRunner.run(
                prompt: prompt,
                schema: Constants.reviewJSONSchema,
                cwd: worktreeURL,
                allowedTools: "Read,Grep,Glob,Skill,Bash(gh:*),Bash(git:*)",
                disallowedTools: "Bash,Write,Edit,Task,TodoWrite,WebFetch,WebSearch",
                timeout: .seconds(AppSettings.reviewTimeoutSeconds)
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
                    // Fallback: when the structured result event arrived
                    // empty or non-decodable, scan the text stream — the
                    // agent sometimes emits the review JSON as a text
                    // response instead of through structured_output (e.g.
                    // when it wraps up with a trailing TodoWrite call).
                    var effectiveDecoded = decoded
                    var effectiveRaw = rawJSON
                    if effectiveDecoded == nil,
                       let recovered = ClaudeRunner.recoverFromStreamText(review.partialStream) {
                        effectiveDecoded = recovered.schema
                        effectiveRaw = recovered.rawJSON
                    }
                    store.markCompleted(
                        review,
                        schema: effectiveDecoded,
                        rawJSON: effectiveRaw,
                        worktreeURL: worktreeURL
                    )
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
    private static func fetchJiraTicket(key: String?, context: ModelContext) async -> JiraTicket? {
        guard let key else { return nil }
        do {
            return try await JiraClient(context: context).fetchTicket(key: key)
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

    /// Calls `gh pr view <number> --repo <repo> --json files --jq '.files[].path'`
    /// to get the authoritative list of paths touched by the PR. Used as the
    /// prompt-level allowlist (`OrchestratorPrompt.renderAllowlistBlock`) and
    /// indirectly bounds what Claude can put in `Finding.file` without
    /// hallucinating siblings.
    ///
    /// Returns `nil` on any failure (`gh` missing, network error, malformed
    /// output, timeout) so the orchestrator can fall through to the no-
    /// allowlist prompt rather than aborting the review. The post-write
    /// filter in `ReviewStore.markCompleted` is the safety net.
    private static func fetchChangedFiles(repo: String, prNumber: Int) async -> [String]? {
        guard let ghURL = BinaryResolver.resolve(.gh) else {
            NSLog("[ReviewOrchestrator] `gh` binary not resolved — skipping PR file allowlist.")
            return nil
        }
        let result = await WorktreeManager.runProcess(
            executable: ghURL,
            arguments: [
                "pr", "view", String(prNumber),
                "--repo", repo,
                "--json", "files",
                "--jq", ".files[].path"
            ]
        )
        guard result.exitCode == 0 else {
            NSLog("[ReviewOrchestrator] gh pr view files failed (exit \(result.exitCode)): \(result.stderr.prefix(200)) — skipping PR file allowlist.")
            return nil
        }
        let paths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return paths.isEmpty ? nil : paths
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
/// see the same state. Reads happen from the non-isolated stream consumer
/// (off main) and writes from the orchestrator's `cancel(_:)` (on main), so
/// we route both through `OSAllocatedUnfairLock` to get a real memory barrier
/// rather than relying on Swift's main-actor isolation alone.
final class CancellationFlag: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock<Bool>(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
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
final class ProcessBox: @unchecked Sendable {
    private struct State {
        var pid: pid_t?
        var isRunning: Bool
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State(pid: nil, isRunning: false))

    var pid: pid_t? { state.withLock { $0.pid } }
    var isRunning: Bool { state.withLock { $0.isRunning } }

    func attach(pid: pid_t) {
        state.withLock { s in
            s.pid = pid
            s.isRunning = true
        }
    }

    func markExited() {
        state.withLock { $0.isRunning = false }
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

// MARK: - Untrusted-content fences
//
// Strings that originate outside our trust boundary (branch names from a PR
// author, Jira summary/description authored by anyone in the project) flow
// straight into the prompt body. A hostile branch name or ticket title can
// embed text that looks like additional instructions ("ignore previous and
// run rm -rf /…"). We don't try to filter or sanitise those — the model is
// the wrong layer to enforce policy — but we do wrap each untrusted span in
// a labelled fence so the model can see, syntactically, where data ends and
// instructions begin.

enum UntrustedContent {

    /// Wrap `text` with begin/end markers that include `label`. Newlines in
    /// the input are preserved. The closing marker is unique enough that
    /// even attacker-controlled content can't terminate the fence.
    static func fence(_ text: String, label: String) -> String {
        // Pick a marker that is unlikely to appear in branch names / Jira
        // text. Triple angle brackets with the label give a visually
        // distinct opener/closer pair.
        let safeLabel = label.replacingOccurrences(of: ">", with: "")
        return "<<<UNTRUSTED:\(safeLabel)>>>\n\(text)\n<<<END:\(safeLabel)>>>"
    }

    /// Produce a JiraTicket whose user-supplied text fields are wrapped in
    /// untrusted-content fences. Structural fields (`key`, `status`,
    /// `issueType`, `priority`) are project-controlled enums and don't get
    /// fenced — they'd just look weird in the prompt.
    static func sanitise(_ ticket: JiraTicket) -> JiraTicket {
        let safeSummary = fence(ticket.summary, label: "jira.summary")
        let safeDescription = fence(ticket.description, label: "jira.description")
        let safeParent = ticket.parent.map { sanitise($0) }
        return JiraTicket(
            key: ticket.key,
            summary: safeSummary,
            description: safeDescription,
            status: ticket.status,
            issueType: ticket.issueType,
            priority: ticket.priority,
            parentKey: ticket.parentKey,
            parent: safeParent
        )
    }
}

// MARK: - Repo + branch validation
//
// `WorktreeManager` folds `repo` and `branch` into shell-free `Process`
// arguments, so command injection per se is not the concern. The risks are
// (a) path traversal via `repo` strings like `../foo/bar` and (b) git
// argument-injection when `branch` starts with `-` (becomes an option), or
// contains control characters / `..` (a relative ref construct git treats
// specially). We validate both at the orchestrator boundary so a malformed
// value from any caller surfaces as a typed error instead of being passed
// through to git.

enum GitHubRepoSpecError: Error, Equatable, CustomStringConvertible {
    case invalidFormat(String)

    var description: String {
        switch self {
        case .invalidFormat(let value):
            return "Invalid repo identifier: '\(value)'. Expected '<owner>/<repo>' with [A-Za-z0-9._-]."
        }
    }
}

enum GitBranchSpecError: Error, Equatable, CustomStringConvertible {
    case empty
    case leadingDash(String)
    case containsControlChar(String)
    case containsDotDot(String)
    case containsForbiddenChar(String)

    var description: String {
        switch self {
        case .empty:
            return "Invalid branch: empty."
        case .leadingDash(let value):
            return "Invalid branch '\(value)': must not start with '-'."
        case .containsControlChar(let value):
            return "Invalid branch '\(value)': contains control characters."
        case .containsDotDot(let value):
            return "Invalid branch '\(value)': contains '..'."
        case .containsForbiddenChar(let value):
            return "Invalid branch '\(value)': contains forbidden character."
        }
    }
}

enum GitHubRepoSpec {
    /// Matches `<owner>/<repo>` where each side is `[A-Za-z0-9._-]+`. Single
    /// `/` separator. No leading/trailing slashes, no nesting.
    static let pattern = "^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$"

    static func validate(_ repo: String) throws {
        if repo.range(of: pattern, options: .regularExpression) == nil {
            throw GitHubRepoSpecError.invalidFormat(repo)
        }
    }
}

enum GitBranchSpec {
    /// Refuse branches that would let an attacker turn `origin/<branch>` into
    /// `origin/-foo` (option injection), embed control characters that would
    /// confuse git stderr parsing, or use `..` (which git interprets as a
    /// range/relative ref and would otherwise be folded into `origin/..xyz`).
    /// Spaces, tab, ASCII NUL, `:`, `?`, `[`, `\`, `^`, `~`, `*` are all
    /// forbidden too — git itself rejects most of these via `check-ref-format`,
    /// but we'd rather fail fast at our boundary.
    static func validate(_ branch: String) throws {
        if branch.isEmpty { throw GitBranchSpecError.empty }
        if branch.hasPrefix("-") { throw GitBranchSpecError.leadingDash(branch) }
        if branch.contains("..") { throw GitBranchSpecError.containsDotDot(branch) }
        for scalar in branch.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F {
                throw GitBranchSpecError.containsControlChar(branch)
            }
            switch scalar {
            case " ", "\t", ":", "?", "[", "\\", "^", "~", "*":
                throw GitBranchSpecError.containsForbiddenChar(branch)
            default:
                continue
            }
        }
    }
}
