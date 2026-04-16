//
//  LocalRepoIndexTests.swift
//  WorkHomepageTests
//
//  Verifies the URL parser, the persistence round-trip, and the directory
//  scanner against a temp filesystem with two synthetic git checkouts laid
//  out as `<root>/<repo>` (flat) and `<root>/<org>/<repo>` (nested) so both
//  layouts produce a usable mapping.
//

import XCTest
@testable import WorkHomepage

final class LocalRepoIndexTests: XCTestCase {

    private var tempDir: URL!
    private var gitURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LocalRepoIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        gitURL = URL(fileURLWithPath: "/usr/bin/git")
        guard FileManager.default.isExecutableFile(atPath: gitURL.path) else {
            throw XCTSkip("/usr/bin/git not available; skipping scan tests.")
        }
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - parseGitHubRepo

    func testParseGitHubRepoSSH() {
        XCTAssertEqual(
            LocalRepoIndex.parseGitHubRepo(from: "git@github.com:Acme/widgets.git"),
            "Acme/widgets"
        )
    }

    func testParseGitHubRepoSSHNoSuffix() {
        XCTAssertEqual(
            LocalRepoIndex.parseGitHubRepo(from: "git@github.com:Acme/widgets"),
            "Acme/widgets"
        )
    }

    func testParseGitHubRepoHTTPS() {
        XCTAssertEqual(
            LocalRepoIndex.parseGitHubRepo(from: "https://github.com/Acme/widgets.git"),
            "Acme/widgets"
        )
    }

    func testParseGitHubRepoSSHURL() {
        XCTAssertEqual(
            LocalRepoIndex.parseGitHubRepo(from: "ssh://git@github.com/Acme/widgets.git"),
            "Acme/widgets"
        )
    }

    func testParseGitHubRepoNonGitHubReturnsNil() {
        XCTAssertNil(LocalRepoIndex.parseGitHubRepo(from: "git@gitlab.com:Acme/widgets.git"))
    }

    // MARK: - Persistence

    func testRootsRoundTrip() {
        let defaults = UserDefaults(suiteName: "LocalRepoIndexTests-roots-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }

        let roots = [
            URL(fileURLWithPath: "/Users/x/src", isDirectory: true),
            URL(fileURLWithPath: "/Users/x/work", isDirectory: true)
        ]
        LocalRepoIndex.setRoots(roots, defaults: defaults)
        let loaded = LocalRepoIndex.roots(defaults: defaults)
        XCTAssertEqual(loaded.map(\.path), roots.map(\.path))
    }

    func testRootsDefaultsToHomeSrcWhenEmpty() {
        let defaults = UserDefaults(suiteName: "LocalRepoIndexTests-default-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }
        let roots = LocalRepoIndex.roots(defaults: defaults)
        XCTAssertEqual(roots.count, 1)
        XCTAssertTrue(roots[0].path.hasSuffix("/src"))
    }

    func testOverridesAndLookupOrder() {
        let defaults = UserDefaults(suiteName: "LocalRepoIndexTests-override-\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "") }

        let scanned = URL(fileURLWithPath: "/scan/Acme/widgets", isDirectory: true)
        let override = URL(fileURLWithPath: "/override/path", isDirectory: true)
        LocalRepoIndex.setMapping(["Acme/widgets": scanned], defaults: defaults)
        XCTAssertEqual(LocalRepoIndex.localPath(for: "Acme/widgets", defaults: defaults)?.path, scanned.path)

        LocalRepoIndex.setOverride(repo: "Acme/widgets", url: override, defaults: defaults)
        XCTAssertEqual(LocalRepoIndex.localPath(for: "Acme/widgets", defaults: defaults)?.path, override.path)

        LocalRepoIndex.setOverride(repo: "Acme/widgets", url: nil, defaults: defaults)
        XCTAssertEqual(LocalRepoIndex.localPath(for: "Acme/widgets", defaults: defaults)?.path, scanned.path)
    }

    // MARK: - scan

    func testScanFindsFlatAndNestedLayouts() throws {
        let root = tempDir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Flat: <root>/widgets, origin = github.com:Acme/widgets
        let flat = root.appendingPathComponent("widgets", isDirectory: true)
        try makeGitRepo(at: flat, originRemote: "git@github.com:Acme/widgets.git")

        // Nested: <root>/Acme/sprockets, origin = github.com:Acme/sprockets
        let nestedOrg = root.appendingPathComponent("Acme", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedOrg, withIntermediateDirectories: true)
        let nested = nestedOrg.appendingPathComponent("sprockets", isDirectory: true)
        try makeGitRepo(at: nested, originRemote: "https://github.com/Acme/sprockets.git")

        // Decoy: non-GitHub origin should be skipped.
        let decoy = root.appendingPathComponent("decoy", isDirectory: true)
        try makeGitRepo(at: decoy, originRemote: "git@gitlab.com:Acme/private.git")

        let mapping = LocalRepoIndex.scan(roots: [root], gitURL: gitURL)
        // Compare resolved paths — `/var` vs `/private/var` symlink expansion
        // differs between the URL we constructed and what `git -C` reports
        // back through the directory walker.
        XCTAssertEqual(
            mapping["Acme/widgets"].map { resolved($0) },
            resolved(flat)
        )
        XCTAssertEqual(
            mapping["Acme/sprockets"].map { resolved($0) },
            resolved(nested)
        )
        XCTAssertNil(mapping["Acme/private"])
    }

    // MARK: - Helpers

    /// Resolves any symlinks in the path (macOS temp dirs live under `/var`
    /// which symlinks to `/private/var`). Returns just the resolved path so
    /// callers can equality-compare without worrying about which form the
    /// scanner produced.
    private func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Creates a real `git init` repo at `path` with the given origin URL set
    /// (it doesn't need to be reachable — `remote get-url` only reads config).
    private func makeGitRepo(at path: URL, originRemote: String) throws {
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "init", "-q", "-b", "main"]).exitCode, 0)
        XCTAssertEqual(run(gitURL, ["-C", path.path, "remote", "add", "origin", originRemote]).exitCode, 0)
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
