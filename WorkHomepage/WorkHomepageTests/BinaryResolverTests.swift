//
//  BinaryResolverTests.swift
//  WorkHomepageTests
//
//  Drives BinaryResolver against a temp directory of fake executables and a
//  per-test UserDefaults suite, so we never touch real Homebrew paths or the
//  developer's actual binary.<tool> defaults.
//

import XCTest
@testable import WorkHomepage

final class BinaryResolverTests: XCTestCase {

    private var tempDir: URL!
    private var defaultsSuite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BinaryResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defaultsSuite = "BinaryResolverTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)
        // Wipe any leftover state in the suite (paranoia — UUID makes collisions effectively impossible).
        for tool in Tool.allCases {
            defaults.removeObject(forKey: BinaryResolver.cacheKey(tool))
            defaults.removeObject(forKey: BinaryResolver.overrideKey(tool))
        }
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        if let defaultsSuite {
            UserDefaults().removePersistentDomain(forName: defaultsSuite)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeFakeBinary(named name: String, in subdir: String? = nil) throws -> URL {
        let dir: URL
        if let subdir {
            dir = tempDir.appendingPathComponent(subdir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } else {
            dir = tempDir
        }
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\necho fake\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - Tests

    func testResolveReturnsFirstExistingCandidate() throws {
        let realPath = try makeFakeBinary(named: "claude", in: "real").path
        let candidates = [
            tempDir.appendingPathComponent("missing/claude").path,   // does not exist
            realPath,                                                // first hit
            tempDir.appendingPathComponent("also/claude").path       // ignored
        ]

        let resolved = BinaryResolver.resolve(.claude, candidates: candidates, defaults: defaults)
        XCTAssertEqual(resolved?.path, realPath)
    }

    func testResolveReturnsNilWhenNoneExist() {
        let candidates = [
            tempDir.appendingPathComponent("nope/a").path,
            tempDir.appendingPathComponent("nada/b").path
        ]
        let resolved = BinaryResolver.resolve(.gh, candidates: candidates, defaults: defaults)
        XCTAssertNil(resolved)
        XCTAssertNil(defaults.string(forKey: BinaryResolver.cacheKey(.gh)))
    }

    func testResolveCachesSuccessfulResolutionForFastLookup() throws {
        let realPath = try makeFakeBinary(named: "git", in: "real").path
        let candidates = [realPath]
        _ = BinaryResolver.resolve(.git, candidates: candidates, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: BinaryResolver.cacheKey(.git)), realPath)
    }

    func testResolveHonoursOverrideOverCandidates() throws {
        let candidatePath = try makeFakeBinary(named: "idea", in: "candidate").path
        let overridePath = try makeFakeBinary(named: "idea", in: "override").path

        BinaryResolver.setOverride(.idea, url: URL(fileURLWithPath: overridePath), defaults: defaults)

        let resolved = BinaryResolver.resolve(.idea, candidates: [candidatePath], defaults: defaults)
        XCTAssertEqual(resolved?.path, overridePath)
    }

    func testValidateReturnsFoundForExistingAndMissingForAbsentTools() throws {
        let claudePath = try makeFakeBinary(named: "claude", in: "claude-dir").path
        let gitPath = try makeFakeBinary(named: "git", in: "git-dir").path

        let candidates: [Tool: [String]] = [
            .claude: [claudePath],
            .gh: [tempDir.appendingPathComponent("nope/gh").path],
            .git: [gitPath],
            .idea: []
        ]

        let result = BinaryResolver.validate(candidates: candidates, defaults: defaults)

        XCTAssertEqual(result[.claude], .found(URL(fileURLWithPath: claudePath)))
        XCTAssertEqual(result[.gh], .missing)
        XCTAssertEqual(result[.git], .found(URL(fileURLWithPath: gitPath)))
        XCTAssertEqual(result[.idea], .missing)
    }

    func testSetOverrideNilClearsTheOverride() throws {
        let overridePath = try makeFakeBinary(named: "idea", in: "ovr").path
        BinaryResolver.setOverride(.idea, url: URL(fileURLWithPath: overridePath), defaults: defaults)
        XCTAssertNotNil(BinaryResolver.readOverride(.idea, defaults: defaults))

        BinaryResolver.setOverride(.idea, url: nil, defaults: defaults)
        XCTAssertNil(BinaryResolver.readOverride(.idea, defaults: defaults))
    }

    func testValidateRespectsOverride() throws {
        let candidatePath = try makeFakeBinary(named: "idea", in: "cand").path
        let overridePath = try makeFakeBinary(named: "idea", in: "ovr").path
        BinaryResolver.setOverride(.idea, url: URL(fileURLWithPath: overridePath), defaults: defaults)

        let candidates: [Tool: [String]] = [
            .claude: [],
            .gh: [],
            .git: [],
            .idea: [candidatePath]
        ]
        let result = BinaryResolver.validate(candidates: candidates, defaults: defaults)
        XCTAssertEqual(result[.idea], .found(URL(fileURLWithPath: overridePath)))
    }

    func testStaleCacheEntryIsIgnoredAndDropped() throws {
        // Seed the cache with a path that no longer exists, then resolve with no
        // candidates — should return nil and clear the cache entry.
        defaults.set(tempDir.appendingPathComponent("ghost/claude").path,
                     forKey: BinaryResolver.cacheKey(.claude))

        let resolved = BinaryResolver.resolve(.claude, candidates: [], defaults: defaults)
        XCTAssertNil(resolved)
        XCTAssertNil(defaults.string(forKey: BinaryResolver.cacheKey(.claude)))
    }

    func testCacheTakesPrecedenceOverProbeWhenStillValid() throws {
        let cachedPath = try makeFakeBinary(named: "gh", in: "cached").path
        let probePath = try makeFakeBinary(named: "gh", in: "probe").path
        defaults.set(cachedPath, forKey: BinaryResolver.cacheKey(.gh))

        // Even though `probePath` would also resolve, the still-existing cached
        // path should win without triggering a probe.
        let resolved = BinaryResolver.resolve(.gh, candidates: [probePath], defaults: defaults)
        XCTAssertEqual(resolved?.path, cachedPath)
    }
}
