//
//  WorktreeAuxFilesTests.swift
//  ForewordTests
//
//  Covers the untracked-helper-file mirror: CLAUDE.md propagates into
//  fresh worktrees, but never stomps content the PR's branch already
//  tracks, and missing source files are silently skipped.
//

import XCTest
@testable import Foreword

final class WorktreeAuxFilesTests: XCTestCase {

    private var tempDir: URL!
    private var sourceRepo: URL!
    private var worktree: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WorktreeAuxFilesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sourceRepo = tempDir.appendingPathComponent("source", isDirectory: true)
        worktree = tempDir.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testMirrorsClaudeMdWhenSourceHasItAndWorktreeDoesnt() throws {
        try "review-rules\n".write(
            to: sourceRepo.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        WorktreeAuxFiles.mirror(from: sourceRepo, to: worktree)

        let mirrored = worktree.appendingPathComponent("CLAUDE.md")
        XCTAssertEqual(try String(contentsOf: mirrored), "review-rules\n")
    }

    func testNoOpWhenSourceHasNoClaudeMd() {
        WorktreeAuxFiles.mirror(from: sourceRepo, to: worktree)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: worktree.appendingPathComponent("CLAUDE.md").path
            ),
            "missing source must not create empty placeholder"
        )
    }

    func testDoesNotStompClaudeMdAlreadyTrackedInWorktree() throws {
        // Worktree already has its own CLAUDE.md (e.g. the PR's branch
        // tracks it). The PR-tracked version must win — we only mirror the
        // user's local helper when the worktree is missing the file.
        try "from-source".write(
            to: sourceRepo.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )
        try "from-pr-branch".write(
            to: worktree.appendingPathComponent("CLAUDE.md"),
            atomically: true,
            encoding: .utf8
        )

        WorktreeAuxFiles.mirror(from: sourceRepo, to: worktree)

        XCTAssertEqual(
            try String(contentsOf: worktree.appendingPathComponent("CLAUDE.md")),
            "from-pr-branch",
            "tracked PR version must survive untouched"
        )
    }
}
