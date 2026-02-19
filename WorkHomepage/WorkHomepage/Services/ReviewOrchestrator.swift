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

        // Step 2: build the prompt. Slice 07 sends PR meta only (no Jira).
        let prompt = Self.buildPrompt(repo: repo, prNumber: prNumber, branch: branch, sha: sha)

        // Step 3: spawn `claude` and consume the stream.
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

        // Step 4: terminal-state housekeeping. If we saw a structured
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

    // MARK: - Prompt

    /// Slice 07 prompt: PR meta only. The agent does its own `gh pr view` /
    /// `gh pr diff` inside the worktree to gather context. Slice 10 adds Jira
    /// context above this.
    static func buildPrompt(repo: String, prNumber: Int, branch: String, sha: String) -> String {
        """
        You are reviewing PR #\(prNumber) in \(repo), branch \(branch).

        Use `gh pr view \(prNumber) --repo \(repo)` and `gh pr diff \(prNumber) --repo \(repo)` to fetch PR details and the diff. Use `git log`, `git blame`, and file reads in the current working directory to understand context. The current directory IS the PR head checked out at SHA \(sha).

        Review the changes for correctness, ticket alignment (no Jira context provided this run), and code quality.

        Return JSON conformant to the provided schema. Findings must reference real file paths and line numbers from the changed files.
        """
    }
}
