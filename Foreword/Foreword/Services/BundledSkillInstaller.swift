//
//  BundledSkillInstaller.swift
//  Foreword
//
//  The default review prompt invokes the `reviewing-pr-final-state` Claude
//  Code skill. Skills live in `~/.claude/skills/<name>/`, so a fresh user
//  wouldn't have it and reviews would silently lose their diff-scoping
//  rules. The app ships a copy (repo `skills/` folder, bundled as
//  `Contents/Resources/skills/`) and installs it on request from the
//  first-run wizard or Settings. An existing skill directory — e.g. the
//  user's own edited version — is never overwritten.
//

import Foundation

enum BundledSkillInstaller {

    enum Status: Equatable {
        case installed
        case alreadyPresent
        case failed(String)
    }

    static let reviewSkillName = "reviewing-pr-final-state"

    /// `~/.claude/skills`, where Claude Code looks for user-level skills.
    static func defaultSkillsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// The `skills` folder inside the app bundle, if present.
    static func bundledSkillsRoot(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "skills", withExtension: nil)
    }

    static func isInstalled(_ name: String, in skillsRoot: URL = defaultSkillsRoot()) -> Bool {
        FileManager.default.fileExists(atPath: skillsRoot.appendingPathComponent(name).path)
    }

    /// Copies `<bundledSkills>/<name>` to `<skillsRoot>/<name>` unless the
    /// destination already exists.
    static func install(
        _ name: String = reviewSkillName,
        from bundledSkills: URL? = bundledSkillsRoot(),
        into skillsRoot: URL = defaultSkillsRoot()
    ) -> Status {
        let fileManager = FileManager.default
        let destination = skillsRoot.appendingPathComponent(name, isDirectory: true)
        if fileManager.fileExists(atPath: destination.path) { return .alreadyPresent }

        guard let source = bundledSkills?.appendingPathComponent(name, isDirectory: true),
              fileManager.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else {
            return .failed("The app bundle doesn't contain the \(name) skill.")
        }
        do {
            try fileManager.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
            try fileManager.copyItem(at: source, to: destination)
            return .installed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
