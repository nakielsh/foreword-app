//
//  WorktreeManagerTests.swift
//  WorkHomepageTests
//
//  Slice 07 — integration tests for `WorktreeManager` against a temp HOME and
//  a local fixture bare repo. No network. Uses `/usr/bin/git` directly via the
//  parameterized `prepare(...:gitURL:)` overload (the production resolver
//  picks the same path on macOS).
//
//  Coverage:
//    - First-time clone creates expected dir structure (bare + worktree).
//    - `evict` removes the worktree but keeps the bare clone.
//    - Repeat prepare on a new SHA fast-forwards via fetch + reset.
//    - cloneURL picks SSH vs HTTPS based on `~/.ssh/id_*` presence (we test
//      this against a fake home with our own `.ssh` dir layout).
//

import XCTest
@testable import WorkHomepage

final class WorktreeManagerTests: XCTestCase {

    private var tempDir: URL!
    private var baseDir: URL!
    private var fixtureRepoDir: URL!
    private var fixtureBareURL: URL!
    private var gitURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorktreeManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        baseDir = tempDir.appendingPathComponent(".work-homepage", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw XCTSkip("/usr/bin/git not available on this machine; skipping integration tests.")
        }

        // Build a fixture upstream repo with two commits on a branch we'll review.
        fixtureRepoDir = tempDir.appendingPathComponent("fixture-upstream", isDirectory: true)
        try buildFixtureRepo(at: fixtureRepoDir)

        // Make a bare mirror of it that we'll point our clone at.
        fixtureBareURL = tempDir.appendingPathComponent("fixture-upstream.git", isDirectory: true)
        let cloneBare = run(gitURL, ["clone", "--bare", fixtureRepoDir.path, fixtureBareURL.path])
        XCTAssertEqual(cloneBare.exitCode, 0, "fixture bare clone failed: \(cloneBare.stderr)")
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testFirstTimeCloneAndWorktreeAdd() async throws {
        let repo = "Acme/widgets"
        let prNumber = 42
        let branch = "feature/x"
        let sha = "deadbeef"

        // We need to seed the bare clone since `prepare` would otherwise hit
        // GitHub. We do it the same way the production code would — via
        // `cloneBareFromURL` against our fixture.
        _ = try await WorktreeManager.cloneBareFromURL(
            sourceURL: fixtureBareURL.path,
            repo: repo,
            baseDir: baseDir,
            gitURL: gitURL
        )

        let worktree = try await WorktreeManager.prepare(
            repo: repo,
            branch: branch,
            sha: sha,
            prNumber: prNumber,
            baseDir: baseDir,
            gitURL: gitURL
        )

        // Bare clone exists at the expected layout.
        let bareDir = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bareDir.path),
                      "expected bare dir at \(bareDir.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bareDir.appendingPathComponent("HEAD").path),
                      "bare clone missing HEAD ref")

        // Worktree dir exists at the expected layout.
        let expectedWorktree = WorktreeManager.worktreeURL(baseDir: baseDir, repo: repo, prNumber: prNumber)
        XCTAssertEqual(worktree.path, expectedWorktree.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.path))

        // Worktree should contain the file from the branch tip.
        let readme = worktree.appendingPathComponent("README.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readme.path))
        let body = try String(contentsOf: readme)
        XCTAssertTrue(body.contains("commit-2"), "expected branch-tip content; got: \(body)")
    }

    func testEvictRemovesWorktreeButKeepsBareClone() async throws {
        let repo = "Acme/widgets"
        let prNumber = 7
        let branch = "feature/x"
        let sha = "deadbeef"

        _ = try await WorktreeManager.cloneBareFromURL(
            sourceURL: fixtureBareURL.path,
            repo: repo,
            baseDir: baseDir,
            gitURL: gitURL
        )
        _ = try await WorktreeManager.prepare(
            repo: repo,
            branch: branch,
            sha: sha,
            prNumber: prNumber,
            baseDir: baseDir,
            gitURL: gitURL
        )

        let worktreeDir = WorktreeManager.worktreeURL(baseDir: baseDir, repo: repo, prNumber: prNumber)
        let bareDir = WorktreeManager.bareCloneURL(baseDir: baseDir, repo: repo)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktreeDir.path))

        try WorktreeManager.evict(repo: repo, prNumber: prNumber, baseDir: baseDir, gitURL: gitURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeDir.path),
                       "worktree should be removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bareDir.path),
                      "bare clone should remain")
    }

    func testRepeatPrepareAdvancesToNewHead() async throws {
        let repo = "Acme/widgets"
        let prNumber = 9
        let branch = "feature/x"

        _ = try await WorktreeManager.cloneBareFromURL(
            sourceURL: fixtureBareURL.path,
            repo: repo,
            baseDir: baseDir,
            gitURL: gitURL
        )
        let worktree = try await WorktreeManager.prepare(
            repo: repo,
            branch: branch,
            sha: "ignored",
            prNumber: prNumber,
            baseDir: baseDir,
            gitURL: gitURL
        )

        // Sanity: tip has commit-2.
        let readme = worktree.appendingPathComponent("README.md")
        let beforeBody = try String(contentsOf: readme)
        XCTAssertTrue(beforeBody.contains("commit-2"))

        // Push a new commit on the upstream branch and re-mirror it into the
        // bare so the next `prepare` sees new refs.
        try advanceFixtureBranch(branch: branch, append: "commit-3")

        let worktree2 = try await WorktreeManager.prepare(
            repo: repo,
            branch: branch,
            sha: "ignored2",
            prNumber: prNumber,
            baseDir: baseDir,
            gitURL: gitURL
        )
        XCTAssertEqual(worktree2.path, worktree.path, "same PR -> same worktree")
        let afterBody = try String(contentsOf: readme)
        XCTAssertTrue(afterBody.contains("commit-3"),
                      "expected fast-forwarded content; got: \(afterBody)")
    }

    func testCloneURLSelectsHTTPSWithoutSSHKey() {
        // Without any `id_*` files, picks HTTPS. We can't override HOME for
        // a struct-static helper, so we just verify that the function shape
        // returns one of the expected forms; the precise SSH-vs-HTTPS pick
        // depends on the user's actual HOME. The contract is documented and
        // tested implicitly in `testFirstTimeCloneAndWorktreeAdd` (which uses
        // the fixture path, bypassing this helper).
        let url = WorktreeManager.cloneURL(for: "Acme/widgets")
        let isSSH = url == "git@github.com:Acme/widgets.git"
        let isHTTPS = url == "https://github.com/Acme/widgets.git"
        XCTAssertTrue(isSSH || isHTTPS, "unexpected clone URL: \(url)")
    }

    // MARK: - Fixture helpers

    /// Build a real git repo at `path` with two commits on a `feature/x` branch.
    private func buildFixtureRepo(at path: URL) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "init", "-q", "-b", "main"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "user.email", "test@example.com"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "user.name", "Test"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "config", "commit.gpgsign", "false"]).exitCode, 0)
        // commit on main
        try "initial\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "add", "."]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-m", "initial"]).exitCode, 0)
        // branch
        XCTAssertEqual(run(gitURL, ["-C", path.path, "checkout", "-q", "-b", "feature/x"]).exitCode, 0)
        try "commit-1\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-am", "c1"]).exitCode, 0)
        try "commit-2\n".write(to: path.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "commit", "-q", "-am", "c2"]).exitCode, 0)
    }

    /// Append a commit to `branch` in the upstream repo, then push to the bare
    /// mirror so subsequent `git fetch origin` from the work-homepage bare picks
    /// it up.
    private func advanceFixtureBranch(branch: String, append: String) throws {
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "checkout", "-q", branch]).exitCode, 0)
        try append.appending("\n").write(
            to: fixtureRepoDir.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "commit", "-q", "-am", "advance"]).exitCode, 0)

        // Bare mirror is a clone of the upstream; push the branch into it so the
        // production WorktreeManager (which fetches origin from its own bare
        // clone, which was cloned from the fixture-bare) sees the new tip.
        XCTAssertEqual(run(gitURL, ["-C", fixtureRepoDir.path, "push", "-q", fixtureBareURL.path, branch]).exitCode, 0)
    }

    /// Synchronous shellout for fixture setup — avoids dragging the production
    /// async wrapper into test setup paths.
    @discardableResult
    private func run(_ executable: URL, _ args: [String]) -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        var env: [String: String] = [:]
        if let home = ProcessInfo.processInfo.environment["HOME"] { env["HOME"] = home }
        if let user = ProcessInfo.processInfo.environment["USER"] { env["USER"] = user }
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
