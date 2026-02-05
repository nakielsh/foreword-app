//
//  PathFormatter.swift
//  WorkHomepage
//
//  Pure helper for displaying filesystem paths in the UI.
//  Mirrors `formatCwd` from index.html — splits `/Users/<username>/x/y/z`
//  into ("~", "/x/y/z") so the home prefix can be rendered dimmed.
//

import Foundation

enum PathFormatter {
    /// Returns (`prefix`, `rest`) split such that:
    /// - `/Users/foo/bar/baz`  → ("~", "/bar/baz")
    /// - `/Users/foo`          → ("~", "")
    /// - `/etc/foo`            → ("",  "/etc/foo")
    /// - `""`                  → ("",  "")
    ///
    /// `prefix` is the part the UI may dim. `rest` is the remainder.
    /// Concatenating `prefix + rest` reproduces the human-readable path.
    static func abbreviateHome(_ path: String) -> (prefix: String, rest: String) {
        guard path.hasPrefix("/Users/") else {
            return ("", path)
        }
        // Strip the "/Users/" leader, then peel off the username segment.
        let afterUsers = path.dropFirst("/Users/".count)
        guard let slashIdx = afterUsers.firstIndex(of: "/") else {
            // Path is exactly `/Users/<username>` with no trailing slash.
            // Treat empty username (just "/Users/") as not-home.
            return afterUsers.isEmpty ? ("", path) : ("~", "")
        }
        let username = afterUsers[..<slashIdx]
        if username.isEmpty {
            return ("", path)
        }
        let rest = String(afterUsers[slashIdx...])
        return ("~", rest)
    }
}
