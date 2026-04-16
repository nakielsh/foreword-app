//
//  IdeaProjectSyncTests.swift
//  WorkHomepageTests
//
//  Verifies the project-model copy: allowed files propagate into the
//  worktree's `.idea/`, denied per-window state is filtered out, and
//  re-syncing refreshes project model without clobbering the worktree's
//  own workspace state.
//

import XCTest
@testable import WorkHomepage

final class IdeaProjectSyncTests: XCTestCase {

    private var tempDir: URL!
    private var sourceRepo: URL!
    private var destRepo: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("IdeaProjectSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        sourceRepo = tempDir.appendingPathComponent("source", isDirectory: true)
        destRepo = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceRepo, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRepo, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Tests

    func testNoOpWhenSourceHasNoIdeaDir() throws {
        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)
        let destIdea = destRepo.appendingPathComponent(".idea")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destIdea.path),
            "no .idea/ in source must not materialise one in dest"
        )
    }

    func testCopiesProjectModelFilesAndSkipsDeniedEntries() throws {
        try makeSourceIdea([
            // Project model — must propagate.
            "modules.xml": "<modules/>",
            "misc.xml": "<misc/>",
            "compiler.xml": "<compiler/>",
            "gradle.xml": "<gradle/>",
            "vcs.xml": "<vcs/>",
            "kotlinc.xml": "<kotlinc/>",
            "backend-rag.iml": "<module/>",
            ".name": "backend-rag",
            ".gitignore": "/workspace.xml\n"
        ])
        // Per-window state — must NOT propagate.
        try writeFile("<workspace/>", to: sourceRepo.appendingPathComponent(".idea/workspace.xml"))
        try writeFile("<tasks/>", to: sourceRepo.appendingPathComponent(".idea/tasks.xml"))
        try FileManager.default.createDirectory(
            at: sourceRepo.appendingPathComponent(".idea/shelf"),
            withIntermediateDirectories: true
        )
        try writeFile("shelved", to: sourceRepo.appendingPathComponent(".idea/shelf/secret.patch"))
        try FileManager.default.createDirectory(
            at: sourceRepo.appendingPathComponent(".idea/httpRequests"),
            withIntermediateDirectories: true
        )
        try writeFile("h", to: sourceRepo.appendingPathComponent(".idea/httpRequests/req.http"))
        try writeFile("<dt/>", to: sourceRepo.appendingPathComponent(".idea/developer-tools.xml"))

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let destIdea = destRepo.appendingPathComponent(".idea")
        for allowed in ["modules.xml", "misc.xml", "compiler.xml", "gradle.xml",
                        "vcs.xml", "kotlinc.xml", "backend-rag.iml", ".name", ".gitignore"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: destIdea.appendingPathComponent(allowed).path),
                "expected project-model file \(allowed) in dest"
            )
        }
        for denied in ["workspace.xml", "tasks.xml", "shelf", "httpRequests", "developer-tools.xml"] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: destIdea.appendingPathComponent(denied).path),
                "denied entry \(denied) must not propagate"
            )
        }
    }

    func testReSyncRefreshesProjectModelButPreservesDestWorkspaceState() throws {
        // Initial: source has v1 project model. Dest already has its own
        // workspace.xml (the worktree's IntelliJ window state).
        try makeSourceIdea(["modules.xml": "<modules version=\"1\"/>"])
        try FileManager.default.createDirectory(
            at: destRepo.appendingPathComponent(".idea"),
            withIntermediateDirectories: true
        )
        let destWorkspace = destRepo.appendingPathComponent(".idea/workspace.xml")
        try writeFile("<workspace from=\"worktree-window\"/>", to: destWorkspace)

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let destModules = destRepo.appendingPathComponent(".idea/modules.xml")
        XCTAssertEqual(try String(contentsOf: destModules), "<modules version=\"1\"/>")
        XCTAssertEqual(
            try String(contentsOf: destWorkspace),
            "<workspace from=\"worktree-window\"/>",
            "denylist must leave existing dest workspace.xml intact"
        )

        // Source advances; re-sync must refresh dest project model.
        try writeFile(
            "<modules version=\"2\"/>",
            to: sourceRepo.appendingPathComponent(".idea/modules.xml")
        )
        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)
        XCTAssertEqual(try String(contentsOf: destModules), "<modules version=\"2\"/>")
        XCTAssertEqual(
            try String(contentsOf: destWorkspace),
            "<workspace from=\"worktree-window\"/>",
            "re-sync must not touch denied entries"
        )
    }

    func testRewritesGradleJvmFromJavaHomeMacroToProjectSDK() throws {
        // Given main repo's misc.xml declares `temurin-21` as project SDK
        // and gradle.xml uses the env-var macro `#JAVA_HOME` (which fails
        // in worktrees launched by GUI macOS apps with empty shell env).
        try makeSourceIdea([
            "misc.xml": ##"<project version="4"><component name="ProjectRootManager" project-jdk-name="temurin-21" project-jdk-type="JavaSDK" /></project>"##,
            "gradle.xml": ##"<project version="4"><component name="GradleSettings"><option name="linkedExternalProjectsSettings"><GradleProjectSettings><option name="gradleJvm" value="#JAVA_HOME" /></GradleProjectSettings></option></component></project>"##
        ])

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let destGradle = try String(contentsOf: destRepo.appendingPathComponent(".idea/gradle.xml"))
        XCTAssertFalse(destGradle.contains("#JAVA_HOME"), "macro should be replaced")
        XCTAssertTrue(destGradle.contains(##"value="temurin-21""##), "should point at project SDK; got: \(destGradle)")
    }

    func testRewriteIsNoOpWhenMiscHasNoProjectJdkName() throws {
        try makeSourceIdea([
            "misc.xml": ##"<project version="4"><component name="ProjectRootManager" /></project>"##,
            "gradle.xml": ##"<option name="gradleJvm" value="#JAVA_HOME" />"##
        ])

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let destGradle = try String(contentsOf: destRepo.appendingPathComponent(".idea/gradle.xml"))
        XCTAssertTrue(destGradle.contains("#JAVA_HOME"), "without a known SDK name we leave the macro intact")
    }

    func testRewriteIsNoOpWhenGradleAlreadyUsesExplicitSDK() throws {
        try makeSourceIdea([
            "misc.xml": ##"<project project-jdk-name="temurin-21" />"##,
            "gradle.xml": ##"<option name="gradleJvm" value="corretto-17" />"##
        ])

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let destGradle = try String(contentsOf: destRepo.appendingPathComponent(".idea/gradle.xml"))
        XCTAssertTrue(destGradle.contains("corretto-17"), "explicit SDK choices must survive untouched")
        XCTAssertFalse(destGradle.contains("temurin-21"), "must not stomp gradle.xml when no #JAVA_HOME present")
    }

    func testCopiesNestedProjectModelDirectories() throws {
        // `runConfigurations/` is a directory full of XML; it must come
        // across as a tree, not just the top-level file list.
        try makeSourceIdea(["modules.xml": "<modules/>"])
        let runConfigsSrc = sourceRepo.appendingPathComponent(".idea/runConfigurations")
        try FileManager.default.createDirectory(at: runConfigsSrc, withIntermediateDirectories: true)
        try writeFile("<config/>", to: runConfigsSrc.appendingPathComponent("Spring_Boot.xml"))

        try IdeaProjectSync.copyProjectModel(from: sourceRepo, to: destRepo)

        let copied = destRepo.appendingPathComponent(".idea/runConfigurations/Spring_Boot.xml")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: copied.path),
            "nested project-model dir must be copied recursively"
        )
    }

    // MARK: - Helpers

    private func makeSourceIdea(_ files: [String: String]) throws {
        let idea = sourceRepo.appendingPathComponent(".idea", isDirectory: true)
        try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
        for (name, content) in files {
            try writeFile(content, to: idea.appendingPathComponent(name))
        }
    }

    private func writeFile(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
