//
//  WorktreeManagerLocalRepoTests.swift
//  ForewordTests
//
//  Verifies the local-repo branch of `WorktreeManager.prepare`/`evict`:
//  worktrees land at the canonical `<baseDir>/worktrees/<repo>/<pr#>` layout
//  (outside the user's checkout, so IntelliJ resolves the worktree as its own
//  project root), repeated prepare fast-forwards, and evict removes the
//  worktree without touching the user's main checkout.
//

import XCTest
@testable import Foreword

final class WorktreeManagerLocalRepoTests: XCTestCase {

    private var tempDir: URL!
    private var fixtureRepoDir: URL!     // upstream working clone (acts as "remote")
    private var localRepoDir: URL!       // user-owned clone (`~/src/<repo>`)
    private var gitURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorktreeManagerLocalRepoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw XCTSkip("/usr/bin/git not available; skipping integration tests.")
        }

        // Build an upstream fixture with a feature branch.
        fixtureRepoDir = tempDir.appendingPathComponent("upstream", isDirectory: true)
        try buildFixtureRepo(at: fixtureRepoDir)

        // Bare mirror so we can clone from a stable "remote".
        let fixtureBareURL = tempDir.appendingPathComponent("upstream.git", isDirectory: true)
        XCTAssertEqual(run(gitURL, ["clone", "--bare", fixtureRepoDir.path, fixtureBareURL.path]).exitCode, 0)

        // The user's local clone — the thing this test puts a worktree
        // alongside.
        localRepoDir = tempDir.appendingPathComponent("local-clone", isDirectory: true)
        XCTAssertEqual(run(gitURL, ["clone", fixtureBareURL.path, localRepoDir.path]).exitCode, 0)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testPrepareCreatesWorktreeAtCanonicalPathOutsideLocalRepo() async throws {
        let baseDir = tempDir.appendingPathComponent("hp-base", isDirectory: true)
        let worktree = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "deadbeef",
            prNumber: 42,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )

        // Worktree lives at canonical `<baseDir>/worktrees/<repo>/<pr#>`,
        // outside the user's checkout so IntelliJ won't inherit a parent
        // project's `.idea`.
        let expected = WorktreeManager.worktreeURL(baseDir: baseDir, repo: "Acme/widgets", prNumber: 42)
        XCTAssertEqual(worktree.path, expected.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))

        // Worktree must NOT be nested inside the user's main checkout.
        XCTAssertFalse(worktree.path.hasPrefix(localRepoDir.path + "/"),
                       "local-repo worktree must not live inside the user's main checkout")

        // Bare-clone path was not created.
        let bareDir = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: "Acme/widgets")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bareDir.path),
                       "local-repo flow must not inflate bare clone")

        // Worktree contains the branch tip.
        let readme = worktree.appendingPathComponent("README.md")
        let body = try String(contentsOf: readme)
        XCTAssertTrue(body.contains("commit-2"), "expected branch-tip content; got: \(body)")
    }

    func testPrepareMirrorsClaudeMdFromLocalRepo() async throws {
        // CLAUDE.md is typically untracked (gitignored or just never
        // committed) so `git worktree add` doesn't bring it across.
        // WorktreeAuxFiles.mirror should fill that gap.
        try "review-rules\n".write(
            to: localRepoDir.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        let baseDir = tempDir.appendingPathComponent("hp-base", isDirectory: true)
        let worktree = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "deadbeef",
            prNumber: 99,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )

        let mirrored = worktree.appendingPathComponent("CLAUDE.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: mirrored.path),
            "CLAUDE.md should be mirrored into the worktree from the user's main checkout"
        )
        XCTAssertEqual(try String(contentsOf: mirrored), "review-rules\n")
    }

    func testPreparePropagatesIdeaProjectModelFromLocalRepo() async throws {
        // Seed the user's clone with a `.idea/` containing a project-model
        // file and a workspace.xml. After prepare, the worktree must have
        // the project-model file (so IntelliJ recognises it) but not the
        // user-state workspace.xml (which would race with the main window).
        let idea = localRepoDir.appendingPathComponent(".idea", isDirectory: true)
        try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
        try "<modules/>".write(
            to: idea.appendingPathComponent("modules.xml"),
            atomically: true,
            encoding: .utf8
        )
        try "<workspace/>".write(
            to: idea.appendingPathComponent("workspace.xml"),
            atomically: true,
            encoding: .utf8
        )

        let baseDir = tempDir.appendingPathComponent("hp-base", isDirectory: true)
        let worktree = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "deadbeef",
            prNumber: 21,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )

        let copiedModules = worktree.appendingPathComponent(".idea/modules.xml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copiedModules.path),
            "project-model file should propagate to worktree"
        )
        let copiedWorkspace = worktree.appendingPathComponent(".idea/workspace.xml")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: copiedWorkspace.path),
            "workspace.xml is per-window state and must not propagate"
        )
    }

    func testRepeatPrepareAdvancesLocalWorktreeToNewHead() async throws {
        let baseDir = tempDir.appendingPathComponent("hp-base", isDirectory: true)
        let worktree = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "deadbeef",
            prNumber: 9,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )
        let readme = worktree.appendingPathComponent("README.md")
        XCTAssertTrue((try String(contentsOf: readme)).contains("commit-2"))

        // Push a new commit on the upstream branch into the bare mirror via
        // the fixture working clone (the local clone's `origin` points at the
        // bare mirror).
        try advanceFixtureBranch(branch: "feature/x", append: "commit-3")

        let worktree2 = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "ignored",
            prNumber: 9,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )
        XCTAssertEqual(worktree2.path, worktree.path)
        XCTAssertTrue((try String(contentsOf: readme)).contains("commit-3"))
    }

    func testEvictRemovesLocalWorktreeButLeavesMainCheckout() async throws {
        let baseDir = tempDir.appendingPathComponent("hp-base", isDirectory: true)
        let worktree = try await WorktreeManager.prepare(
            repo: "Acme/widgets",
            branch: "feature/x",
            sha: "deadbeef",
            prNumber: 7,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))

        try WorktreeManager.evict(
            repo: "Acme/widgets",
            prNumber: 7,
            baseDir: baseDir,
            gitURL: gitURL,
            localRepoURL: localRepoDir
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.path))
        // User's main checkout is untouched.
        XCTAssertTrue(FileManager.default.fileExists(atPath: localRepoDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: localRepoDir.appendingPathComponent("README.md").path))
    }

    // MARK: - Fixture helpers

    private func buildFixtureRepo(at path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "init", "-q", "-b", "main"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "user.email", "test@example.com"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "user.name", "Test"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "commit.gpgsign", "false"]).exitCode, 0)
        try "initial\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "add", "."]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-m", "initial"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "checkout", "-q", "-b", "feature/x"]).exitCode, 0)
        try "commit-1\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-am", "c1"]).exitCode, 0)
        try "commit-2\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-am", "c2"]).exitCode, 0)
    }

    private func advanceFixtureBranch(branch: String, append: String) throws {
        let bareURL = tempDir.appendingPathComponent("upstream.git", isDirectory: true)
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "checkout", "-q", branch]).exitCode, 0)
        try append.appending("\n").write(
            to: fixtureRepoDir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "commit", "-q", "-am", "advance"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "push", "-q", bareURL.path, branch]).exitCode, 0)
    }

    @discardableResult
    private func run(_ executable: URL, _ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        process.environment = env
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        do { try process.run() } catch {
            return (-1, "", "spawn failed: \(error)")
        }
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, out, err)
    }
}
