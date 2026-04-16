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
    /// Resolves the on-disk worktree URL for the given PR. When
    /// `LocalRepoIndex` has a mapping for `repoFullName`, returns
    /// `<localRepo>/.worktrees/<prNumber>` so launchers open the user's clone.
    /// Otherwise falls back to the bare-clone layout under
    /// `~/.work-homepage/worktrees/<repoFullName>/<prNumber>`.
    /// `repoFullName` is `<org>/<repo>` (e.g. `Ala-com/work-homepage`).
    static func url(for repoFullName: String, prNumber: Int) -> URL {
        if let local = LocalRepoIndex.localPath(for: repoFullName) {
            return WorktreeManager.localWorktreeURL(localRepoURL: local, prNumber: prNumber)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appending(path: ".work-homepage")
            .appending(path: "worktrees")
            .appending(path: repoFullName)
            .appending(path: "\(prNumber)")
    }
}
