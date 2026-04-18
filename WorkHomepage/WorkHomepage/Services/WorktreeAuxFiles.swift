//
//  WorktreeAuxFiles.swift
//  WorkHomepage
//
//  Mirrors a small allowlist of untracked helper files from the user's
//  main checkout into a freshly-prepared worktree.
//
//  `git worktree add` only checks out tracked files, so review-helper
//  artefacts the user keeps locally — `CLAUDE.md` instructions, AGENT.md
//  rules, that kind of thing — never make it into the worktree. Reviewers
//  rely on these notes to ground their AI tooling against the codebase, so
//  re-running a review without them produces lower-quality findings.
//
//  Allowlist (not a denylist) by design — we don't want to copy
//  `local.properties`, `.env`, or other sensitive untracked files. Each
//  entry is a plain top-level filename; subdirectory mirroring isn't
//  supported because it'd have to reckon with `.gitignore`, and the cost
//  of a misclassification is leaking secrets into a worktree that other
//  tooling indexes.
//

import Foundation

enum WorktreeAuxFiles {

    /// Top-level filenames mirrored from the user's main checkout into the
    /// worktree when (a) the source has the file and (b) the worktree
    /// doesn't already (so we never overwrite content that was tracked in
    /// the PR's branch).
    static let filenames: [String] = [
        "CLAUDE.md"
    ]

    /// Best-effort copy. Failures on individual files are swallowed —
    /// missing aux files shouldn't block a review from starting.
    static func mirror(from sourceRepo: URL, to worktree: URL) {
        let fm = FileManager.default
        for name in filenames {
            let src = sourceRepo.appending(path: name)
            let dst = worktree.appending(path: name)
            guard fm.fileExists(atPath: src.path) else { continue }
            // Don't stomp anything the worktree's branch tracks. If the
            // PR happens to include `CLAUDE.md`, that version wins.
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.copyItem(at: src, to: dst)
        }
    }
}
