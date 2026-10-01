//
//  BundledSkillInstallerTests.swift
//  ForewordTests
//
//  The default review prompt invokes the `reviewing-pr-final-state` skill.
//  The app ships a copy and installs it into `~/.claude/skills` on request.
//  Tests run against temp skills roots; one test checks the app bundle
//  really carries the skill.
//

import XCTest
@testable import Foreword

@MainActor
final class BundledSkillInstallerTests: XCTestCase {

    private var tempDir: URL!
    private var bundledSkills: URL!
    private var skillsRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BundledSkillInstallerTests-\(UUID().uuidString)", isDirectory: true)
        bundledSkills = tempDir.appendingPathComponent("bundle/skills", isDirectory: true)
        skillsRoot = tempDir.appendingPathComponent("home/.claude/skills", isDirectory: true)
        try write("---\nname: demo-skill\n---\nbody\n", to: bundledSkills.appendingPathComponent("demo-skill/SKILL.md"))
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testCopiesBundledSkillWhenAbsent() throws {
        assertThat(BundledSkillInstaller.isInstalled("demo-skill", in: skillsRoot)).isFalse()

        let status = BundledSkillInstaller.install("demo-skill", from: bundledSkills, into: skillsRoot)

        assertThat(status).isEqualTo(.installed)
        assertThat(BundledSkillInstaller.isInstalled("demo-skill", in: skillsRoot)).isTrue()
        assertThat(try read(skillsRoot.appendingPathComponent("demo-skill/SKILL.md")))
            .isEqualTo("---\nname: demo-skill\n---\nbody\n")
    }

    func testNeverOverwritesAnExistingSkill() throws {
        try write("user's own version\n", to: skillsRoot.appendingPathComponent("demo-skill/SKILL.md"))

        let status = BundledSkillInstaller.install("demo-skill", from: bundledSkills, into: skillsRoot)

        assertThat(status).isEqualTo(.alreadyPresent)
        assertThat(try read(skillsRoot.appendingPathComponent("demo-skill/SKILL.md"))).isEqualTo("user's own version\n")
    }

    func testFailsWhenTheBundleLacksTheSkill() {
        let status = BundledSkillInstaller.install("missing-skill", from: bundledSkills, into: skillsRoot)

        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
        assertThat(BundledSkillInstaller.isInstalled("missing-skill", in: skillsRoot)).isFalse()
    }

    func testFailsWhenTheSkillsRootIsNotWritable() throws {
        // A file where the skills directory should be.
        try write("not a directory", to: skillsRoot)

        let status = BundledSkillInstaller.install("demo-skill", from: bundledSkills, into: skillsRoot)

        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
    }

    func testAppBundleShipsTheReviewSkill() throws {
        let bundled = try XCTUnwrap(BundledSkillInstaller.bundledSkillsRoot(), "app bundle has no skills folder")
        let skill = bundled
            .appendingPathComponent(BundledSkillInstaller.reviewSkillName)
            .appendingPathComponent("SKILL.md")

        assertThat(try read(skill)).contains("name: reviewing-pr-final-state")
    }

    // MARK: - Helpers

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }
}
