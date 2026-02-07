//
//  Deployment.swift
//  WorkHomepage
//
//  Slice 05: a parsed deployment derived from a workflow run.
//

import struct Foundation.URL
import struct Foundation.Date

struct Deployment: Hashable {
    let env: String
    let version: String
    let runName: String
    let createdAt: Date
    let htmlURL: URL
    let conclusion: String?

    /// Snapshot if the version is anything other than a strict `MAJOR.MINOR.PATCH`.
    /// Mirrors index.html: `!/^\d+\.\d+\.\d+$/.test(version)`.
    var isSnapshot: Bool {
        let pattern = #"^\d+\.\d+\.\d+$"#
        return version.range(of: pattern, options: .regularExpression) == nil
    }
}
