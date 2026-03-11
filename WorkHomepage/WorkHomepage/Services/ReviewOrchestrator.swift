//
//  ReviewOrchestrator.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Composition root for "click Review on a PR -> Claude review row in
//  SwiftData". Single-flight in slice 07: at most one review may be running.
//  Slice 13 will replace the boolean gate with a proper queue + concurrency cap.
//
//  Pipeline:
//    1. Insert a `Review` row in `running` state via ReviewStore.
//    2. Prepare the worktree (clone-on-first-use, then worktree add or reset).
//    3. Build the prompt (PR meta only — no Jira until slice 10).
//    4. Spawn `claude` via ClaudeRunner.
//    5. For each event, append to the row's partial stream / mark final.
//    6. Mark the row completed/failed/timeout.
//
//  All UI-visible state changes happen on the main actor through the store.
//

import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ReviewOrchestrator {

    /// Process-wide singleton. Slice 07 has exactly one orchestrator alive at
    /// any time; the singleton lets the Review button on each PR card observe
    /// `isRunning` without prop-drilling.
    static let shared = ReviewOrchestrator()

    /// The currently running (or most recently completed) review. Bound to the
    /// modal sheet so it can render live state via SwiftData observation.
    /// `current?.state == "running"` is the single-flight gate.
    var current: Review?

    /// True iff a review is in `running` state right now.
    var isRunning: Bool { current?.state == "running" }

    /// Last user-visible error not tied to a specific Review row (e.g.
    /// single-flight rejection). Cleared when a new run starts.
    var lastRejection: String?

    /// Hold the underlying stream task so `cancel()` can drop it. Slice 07's
    /// UI doesn't expose cancellation; slice 13 adds the button.
    private var streamTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Kick off a review. Idempotent against single-flight: a second call while
    /// `isRunning` is true sets `lastRejection` and returns without touching
    /// anything.
    func start(
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        store: ReviewStore
    ) async {
        if isRunning {
            lastRejection = "A review is already running. Wait for it to finish before starting another."
            return
        }
        lastRejection = nil

        let prKey = "\(repo)#\(prNumber)"
        let review = store.addReview(
            prKey: prKey,
            repoFullName: repo,
            prNumber: prNumber,
            headSha: sha,
            headBranch: branch
        )
        current = review

        // Run the pipeline as a detached-but-tracked task so it survives view
        // dismissal (the modal can be closed; the run continues, the result
        // lands in SwiftData, and re-opening the modal shows the latest state).
        streamTask = Task { [weak self] in
            await self?.execute(review: review, repo: repo, prNumber: prNumber, branch: branch, sha: sha, store: store)
        }
    }

    /// Cancel the currently running review. Slice 07 doesn't surface this in
    /// the UI but the hook is here for slice 13.
    func cancel() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Clear the currently surfaced review reference. Used by the global
    /// "Active review" pill's dismiss button. Does not cancel an in-flight
    /// run — call `cancel()` first if you mean to. Refuses to clear while a
    /// review is still running so the user can't accidentally lose the UI
    /// handle to a live process.
    func clearCurrent() {
        guard !isRunning else { return }
        current = nil
        lastRejection = nil
    }

    // MARK: - Pipeline

    private func execute(
        review: Review,
        repo: String,
        prNumber: Int,
        branch: String,
        sha: String,
        store: ReviewStore
    ) async {
        // Step 1: prepare the worktree.
        let worktreeURL: URL
        do {
            worktreeURL = try await WorktreeManager.prepare(
                repo: repo,
                branch: branch,
                sha: sha,
                prNumber: prNumber
            )
        } catch {
            store.markFailed(review, error: "Worktree prep failed: \(error)")
            return
        }

        // Step 2: resolve Jira context (slice 10).
        // Extract a ticket key from the head branch (e.g. `feature/JWT-123`).
        // Record what we attempted on the Review row regardless of whether
        // the fetch succeeds — slice 08's modal header surfaces this.
        let jiraKey = TicketKeyExtractor.extract(branchName: branch)
        if let jiraKey {
            review.jiraKey = jiraKey
            try? store.context.save()
        }

        let jiraTicket = await fetchJiraTicket(key: jiraKey)

        // Step 3: build the prompt. With Jira context above PR meta when
        // available; otherwise the prompt opens with `Jira: null`.
        let prompt = OrchestratorPrompt.build(
            repo: repo,
            prNumber: prNumber,
            branch: branch,
            sha: sha,
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
            store.markFailed(review, error: "`claude` binary not found. Configure it in Settings.")
            return
        } catch {
            store.markFailed(review, error: "Failed to launch claude: \(error)")
            return
        }

        var sawTerminalEvent = false
        var lastError: String?

        do {
            for try await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .textDelta(let text):
                    store.appendStream(review, text: text)
                case .toolUse(let name):
                    // Annotate the partial stream so the user sees tool usage
                    // inline. Cosmetic in slice 07; slice 08+ may prettify.
                    store.appendStream(review, text: "\n[tool: \(name)]\n")
                case .finalResult(let rawJSON, let decoded):
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

        // Step 5: terminal-state housekeeping. If we saw a structured
        // `.finalResult`, the row is already `completed`. Otherwise classify
        // the failure.
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
    /// available. Returns nil for the (common) "no Jira" cases:
    ///   - branch had no recognised ticket key,
    ///   - Jira credentials weren't configured,
    ///   - the ticket wasn't found,
    ///   - 401 or other HTTP failure (logged, swallowed),
    ///   - underlying URLSession threw (offline, DNS, …).
    /// The orchestrator never blocks the review on Jira problems.
    private func fetchJiraTicket(key: String?) async -> JiraTicket? {
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

    // MARK: - Prompt

    /// Compatibility shim for callers that referenced the legacy slice 07
    /// prompt builder. New code should call `OrchestratorPrompt.build`
    /// directly so it can pass a `JiraTicket?`. Pure function — no actor
    /// isolation required.
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
