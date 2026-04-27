//
//  WorktreeManagerInFlightDedupTests.swift
//  WorkHomepageTests
//
//  Pin the desired contract: when two callers fire `prepare(...)` for the
//  same `(repo, prNumber)` while a previous call is mid-flight, only ONE
//  git operation should run; the second caller awaits the first and
//  receives the same worktree URL. Today the production `WorktreeManager`
//  does NOT de-duplicate — concurrent prepares race against each other,
//  re-running clone/fetch and occasionally tripping the "worktree already
//  registered" error. This test is parked behind `XCTSkipIf(true, ...)`
//  with a FIXME so the next agent who adds the actor / serial gate can
//  flip the skip and use the test as the regression fence.
//

import XCTest
@testable import WorkHomepage

final class WorktreeManagerInFlightDedupTests: XCTestCase {

    // MARK: - Two concurrent prepares for the same (repo, prNumber)

    func testConcurrentPrepareForSameKeyDeduplicates() async throws {
        // FIXME: WorktreeManager has no in-flight de-duplication for
        // concurrent prepare(...) calls. The orchestrator's queue serialises
        // most callers but a second click on the same PR within the same
        // tick can still land twice. Acceptance shape:
        //   - Two starts for the same (repo, prNumber) must result in EXACTLY
        //     ONE git clone / fetch process spawned (count via a fake gitURL
        //     wrapper).
        //   - Both prepare(...) Tasks must resolve with the same URL.
        // Implementation sketch: per-key actor in WorktreeManager keyed on
        // `<repo>#<prNumber>` that wraps the bare-clone + worktree-add steps.
        try XCTSkipIf(true, "WorktreeManager.prepare(...) does not de-duplicate concurrent calls for the same key. See FIXME and the desired contract above.")

        let tempBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WMDedup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }

        // Build a tiny local origin so we don't hit the network.
        let originURL = tempBase.appendingPathComponent("origin.git")
        let workURL = tempBase.appendingPathComponent("seed")
        let gitURL = URL(fileURLWithPath: "/usr/bin/git")
        try seedOrigin(at: originURL, work: workURL, gitURL: gitURL)

        // Two concurrent prepares for the SAME (repo, prNumber).
        async let a = WorktreeManager.prepare(
            repo: "owner/repo",
            branch: "main",
            sha: "HEAD",
            prNumber: 7,
            baseDir: tempBase,
            gitURL: gitURL,
            localRepoURL: workURL
        )
        async let b = WorktreeManager.prepare(
            repo: "owner/repo",
            branch: "main",
            sha: "HEAD",
            prNumber: 7,
            baseDir: tempBase,
            gitURL: gitURL,
            localRepoURL: workURL
        )

        let resolved = try await [a, b]
        // Both callers see the same worktree URL.
        XCTAssertEqual(resolved[0].path, resolved[1].path)
    }

    // MARK: - Helpers

    /// Spin up a tiny git repo at `originURL` (bare) plus a working copy
    /// at `workURL` so `prepare(...)` has something to clone from. Used by
    /// the migration / dedup tests above; the local-clone code path needs
    /// a real repo on disk.
    private func seedOrigin(at originURL: URL, work workURL: URL, gitURL: URL) throws {
        try FileManager.default.createDirectory(at: workURL, withIntermediateDirectories: true)
        run(gitURL, ["init", "-b", "main", workURL.path])
        run(gitURL, ["-C", workURL.path, "config", "user.email", "test@example.com"])
        run(gitURL, ["-C", workURL.path, "config", "user.name", "Test"])
        try "hello\n".write(to: workURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        run(gitURL, ["-C", workURL.path, "add", "."])
        run(gitURL, ["-C", workURL.path, "commit", "-m", "initial"])
        run(gitURL, ["clone", "--bare", workURL.path, originURL.path])
        run(gitURL, ["-C", workURL.path, "remote", "add", "origin", originURL.path])
        run(gitURL, ["-C", workURL.path, "fetch", "origin"])
    }

    @discardableResult
    private func run(_ exe: URL, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
