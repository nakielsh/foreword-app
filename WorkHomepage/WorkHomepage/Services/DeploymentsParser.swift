//
//  DeploymentsParser.swift
//  WorkHomepage
//
//  Pure parser that mirrors index.html's `parseDeployRun` regex.
//  Extracts (env, version) from workflow run names like:
//      [dev] Deploy v1.21.1-feature-jwt-943-snapshot apply w/out WAF
//      [prod] Deploy v1.21.1
//

import Foundation

/// Compiled once at file scope. The pattern is a Swift literal that never
/// changes across runs, so a malformed regex is a programmer error and
/// should fail-fast at first use rather than silently turn every parse into
/// a `nil`. `try!` makes that contract explicit; `try?` previously hid the
/// failure as "no deployment ever matches", which is undebuggable in the UI.
private let deploymentRunRegex: NSRegularExpression = try! NSRegularExpression(
    // Mirror JS: /^\[(\w+)\]\s+Deploy\s+v?([\S]+?)(?:\s+apply|$)/i
    // Swift NSRegularExpression doesn't accept inline `(?i)` cleanly
    // alongside our anchors here, so we use options: .caseInsensitive.
    pattern: #"^\[(\w+)\]\s+Deploy\s+v?(\S+?)(?:\s+apply|$)"#,
    options: [.caseInsensitive]
)

enum DeploymentsParser {
    struct ParsedRun: Equatable {
        let env: String
        let version: String
    }

    /// Parses a workflow run name. Returns nil for names that don't match
    /// `[<env>] Deploy [v]<version>[ apply ...]`.
    static func parse(runName: String) -> ParsedRun? {
        let range = NSRange(runName.startIndex..<runName.endIndex, in: runName)

        guard let match = deploymentRunRegex.firstMatch(in: runName, options: [], range: range),
              match.numberOfRanges >= 3,
              let envRange = Range(match.range(at: 1), in: runName),
              let versionRange = Range(match.range(at: 2), in: runName) else {
            return nil
        }

        let env = runName[envRange].lowercased()
        let version = String(runName[versionRange])
        guard !env.isEmpty, !version.isEmpty else { return nil }
        return ParsedRun(env: env, version: version)
    }
}
