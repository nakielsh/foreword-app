//
//  WorktreePath.swift
//  WorkHomepage
//
//  Slice 09 — IntelliJ launcher.
//
//  Tiny helper that derives the on-disk worktree directory for a given PR
//  (`~/.work-homepage/worktrees/<repoFullName>/<prNumber>/`) without depending
//  on `WorktreeManager`. The launcher needs this URL to know which project
//  IntelliJ should index, but slice 09 must not modify `WorktreeManager.swift`
//  (parallel slice 17 work touches it). Same disk layout as
//  `WorktreeManager.worktreeURL(baseDir:repo:prNumber:)`, just carved out so
//  the UI layer can reach it independently.
//

import Foundation

enum WorktreePath {
    /// Resolves the on-disk worktree URL for the given PR. Both flows (bare
    /// clone and user-owned clone) place the worktree at the canonical
    /// `~/.work-homepage/worktrees/<repoFullName>/<prNumber>` location, so the
    /// launcher always points IntelliJ at a directory that lives outside any
    /// other project root.
    /// `repoFullName` is `<org>/<repo>` (e.g. `acme/widgets`).
    static func url(for repoFullName: String, prNumber: Int) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appending(path: ".work-homepage")
            .appending(path: "worktrees")
            .appending(path: repoFullName)
            .appending(path: "\(prNumber)")
    }
}
