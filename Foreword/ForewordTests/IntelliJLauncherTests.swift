//
//  IntelliJLauncherTests.swift
//  ForewordTests
//
//  Slice 09 — IntelliJ launcher.
//
//  Drives `IntelliJLauncher` through its testable injection seams: the
//  resolver closure is faked with a temp "fake idea" binary URL (we never
//  actually launch it), and the spawn closure is replaced with one that
//  records what would have been spawned. We deliberately do NOT exercise the
//  default `Process` spawn nor `NSWorkspace.shared.open` — those would launch
//  real GUI apps on the developer's machine.
//

import XCTest
@testable import Foreword

final class IntelliJLauncherTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IntelliJLauncherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeWorktree(withFile relPath: String) throws -> (worktree: URL, file: String) {
        let worktree = tempDir.appendingPathComponent("worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let fileURL = worktree.appending(path: relPath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "// fake source".write(to: fileURL, atomically: true, encoding: .utf8)
        return (worktree, relPath)
    }

    private func makeFakeIdea() throws -> URL {
        let url = tempDir.appendingPathComponent("idea")
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - WorktreePath

    func testWorktreePathReturnsExpectedLayout() {
        let url = WorktreePath.url(for: "acme/widgets", prNumber: 42)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let expected = home
            .appending(path: ".foreword")
            .appending(path: "worktrees")
            .appending(path: "acme/widgets")
            .appending(path: "42")
        assertThat(url.path).isEqualTo(expected.path)
    }

    // MARK: - open(...)

    func testOpenThrowsIdeaCLINotFoundWhenResolverReturnsNil() throws {
        let (worktree, file) = try makeWorktree(withFile: "src/Foo.swift")

        do {
            try IntelliJLauncher.open(
                worktree: worktree,
                file: file,
                line: 7,
                resolveIdea: { nil },
                spawn: { _, _ in
                    XCTFail("spawn should not be invoked when idea CLI is missing")
                }
            )
            XCTFail("expected ideaCLINotFound to throw")
        } catch let error as IntelliJLauncher.LaunchError {
            assertThat(error).isEqualTo(.ideaCLINotFound)
        }
    }

    func testOpenThrowsFileNotFoundWhenFileMissingFromWorktree() throws {
        let (worktree, _) = try makeWorktree(withFile: "src/Real.swift")
        let ideaURL = try makeFakeIdea()
        let missingFile = "src/Hallucinated.swift"

        do {
            try IntelliJLauncher.open(
                worktree: worktree,
                file: missingFile,
                line: 12,
                resolveIdea: { ideaURL },
                spawn: { _, _ in
                    XCTFail("spawn should not be invoked when file is missing")
                }
            )
            XCTFail("expected fileNotFoundInWorktree to throw")
        } catch let error as IntelliJLauncher.LaunchError {
            let expectedURL = worktree.appending(path: missingFile)
            assertThat(error).isEqualTo(.fileNotFoundInWorktree(expectedURL))
        }
    }

    func testOpenSpawnsIdeaWithLineAndFilePathWhenAllPresent() throws {
        let (worktree, file) = try makeWorktree(withFile: "src/Foo.swift")
        let ideaURL = try makeFakeIdea()

        var spawnedExecutable: URL?
        var spawnedArguments: [String]?

        try IntelliJLauncher.open(
            worktree: worktree,
            file: file,
            line: 42,
            resolveIdea: { ideaURL },
            spawn: { exe, args in
                spawnedExecutable = exe
                spawnedArguments = args
            }
        )

        assertThat(spawnedExecutable?.path).isEqualTo(ideaURL.path)
        let expectedFilePath = worktree.appending(path: file).path
        // Worktree project dir is passed as the first positional so IntelliJ
        // routes the navigation to that project (not whichever window happens
        // to be active). `--line` then applies to the file path.
        assertThat(spawnedArguments).isEqualTo([worktree.path, "--line", "42", expectedFilePath])
    }

    // MARK: - openWithFallback(...)

    func testOpenWithFallbackReturnsFileMissingWhenFileAbsent() throws {
        let (worktree, _) = try makeWorktree(withFile: "src/Real.swift")
        let ideaURL = try makeFakeIdea()
        let missing = "src/Ghost.swift"

        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: missing,
            line: 1,
            resolveIdea: { ideaURL },
            spawn: { _, _ in XCTFail("spawn should not run for missing file") },
            workspaceOpen: { _ in
                XCTFail("workspaceOpen should not run for missing file")
                return false
            }
        )

        let expectedURL = worktree.appending(path: missing)
        assertThat(result).isEqualTo(.fileMissing(expectedURL))
    }

    func testOpenWithFallbackReturnsOpenedInIntelliJOnSuccess() throws {
        let (worktree, file) = try makeWorktree(withFile: "src/Foo.swift")
        let ideaURL = try makeFakeIdea()

        var didSpawn = false
        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: file,
            line: 9,
            resolveIdea: { ideaURL },
            spawn: { _, _ in didSpawn = true },
            workspaceOpen: { _ in
                XCTFail("workspaceOpen should not run on idea success")
                return false
            }
        )

        assertThat(didSpawn).isTrue()
        assertThat(result).isEqualTo(.openedInIntelliJ)
    }

    func testOpenWithFallbackFallsBackToWorkspaceWhenIdeaMissing() throws {
        let (worktree, file) = try makeWorktree(withFile: "src/Foo.swift")

        var workspaceCalledWith: URL?
        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: file,
            line: 9,
            resolveIdea: { nil },
            spawn: { _, _ in XCTFail("spawn should not run when idea missing") },
            workspaceOpen: { url in
                workspaceCalledWith = url
                return true
            }
        )

        assertThat(workspaceCalledWith?.path).isEqualTo(worktree.appending(path: file).path)
        assertThat(result).isEqualTo(.openedWithoutLineJump)
    }

    func testOpenWithFallbackReturnsFailedWhenWorkspaceOpenReturnsFalse() throws {
        let (worktree, file) = try makeWorktree(withFile: "src/Foo.swift")

        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: file,
            line: 9,
            resolveIdea: { nil },
            spawn: { _, _ in XCTFail("spawn should not run when idea missing") },
            workspaceOpen: { _ in false }
        )

        switch result {
        case .failed:
            break
        default:
            XCTFail("expected .failed, got \(result)")
        }
    }

    func testOpenWithFallbackReturnsFileMissingWhenIdeaMissingAndFileAlsoMissing() throws {
        let (worktree, _) = try makeWorktree(withFile: "src/Real.swift")
        let missing = "src/Ghost.swift"

        let result = IntelliJLauncher.openWithFallback(
            worktree: worktree,
            file: missing,
            line: 9,
            resolveIdea: { nil },
            spawn: { _, _ in XCTFail("spawn should not run") },
            workspaceOpen: { _ in
                XCTFail("workspaceOpen should not run when file is missing")
                return false
            }
        )

        let expectedURL = worktree.appending(path: missing)
        assertThat(result).isEqualTo(.fileMissing(expectedURL))
    }

    // MARK: - missingFileHint

    func testMissingFileHintListsClosestSiblingsWhenParentExists() throws {
        let (worktree, _) = try makeWorktree(withFile: "src/app/ConfluencePageSyncService.kt")
        let parent = worktree.appending(path: "src/app")
        try "// other".write(
            to: parent.appendingPathComponent("ConfluenceSyncService.kt"),
            atomically: true,
            encoding: .utf8
        )
        try "// other".write(
            to: parent.appendingPathComponent("ConfluenceTokenProvider.kt"),
            atomically: true,
            encoding: .utf8
        )

        let hint = IntelliJLauncher.missingFileHint(
            worktree: worktree,
            file: "src/app/ConfluencePageQueryService.kt"
        )

        let unwrapped = try XCTUnwrap(hint)
        assertThat(unwrapped).contains("directory exists but the file does not")
        assertThat(unwrapped).contains("ConfluencePageSyncService.kt")
    }

    func testMissingFileHintReportsDeepestExistingAncestorWhenParentMissing() throws {
        let (worktree, _) = try makeWorktree(withFile: "src/app/Real.kt")

        let hint = IntelliJLauncher.missingFileHint(
            worktree: worktree,
            file: "src/app/missing-subdir/deeper/Thing.kt"
        )

        let unwrapped = try XCTUnwrap(hint)
        assertThat(unwrapped).contains("first missing segment")
        assertThat(unwrapped).contains("missing-subdir")
    }

    func testMissingFileHintReportsAbsentWorktree() {
        let nonexistent = tempDir.appendingPathComponent("never-created", isDirectory: true)

        let hint = IntelliJLauncher.missingFileHint(
            worktree: nonexistent,
            file: "anything.kt"
        )

        let unwrapped = hint ?? ""
        assertThat(unwrapped).contains("worktree directory itself does not exist")
    }

    func testMissingFileHintReturnsNilForInvalidInput() {
        let hint = IntelliJLauncher.missingFileHint(
            worktree: tempDir,
            file: "/absolute/rejected.kt"
        )
        XCTAssertNil(hint)
    }
}

// AssertJ-flavoured helpers consolidated into Helpers/Assertions.swift —
// the per-file FluentAssertion shim has been removed.
