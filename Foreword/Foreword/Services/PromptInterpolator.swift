//
//  PromptInterpolator.swift
//  Foreword
//
//  Slice 23 — Custom Review Prompt Template.
//
//  Pure string utilities for `{{key}}` template interpolation.
//  No external dependencies; no side effects.
//
//  `interpolate`: replaces every `{{key}}` occurrence (whitespace inside
//  braces tolerated: `{{ key }}`). Keys not present in `vars` are left
//  in their original literal form so callers can distinguish "not set" from
//  "empty string".
//
//  `unknownVariables`: returns variable names referenced in the template
//  but absent from `knownKeys`. Deduplicated, ordered by first appearance.
//

import Foundation

enum PromptInterpolator {

    // Matches `{{key}}` and `{{ key }}` — any amount of horizontal whitespace
    // inside the double-brace delimiters is stripped before lookup.
    private static let tokenPattern: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: #"\{\{\s*(\w+)\s*\}\}"#)
    }()

    /// Replace every `{{key}}` token in `template` with the corresponding
    /// value from `vars`. Tokens whose key is absent from `vars` are left
    /// verbatim (including their braces) so the caller can detect them.
    static func interpolate(_ template: String, vars: [String: String]) -> String {
        let nsTemplate = template as NSString
        let fullRange = NSRange(location: 0, length: nsTemplate.length)
        var result = template
        // Enumerate matches in reverse so that index arithmetic stays stable
        // as we replace substrings.
        let matches = tokenPattern.matches(in: template, range: fullRange)
        for match in matches.reversed() {
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound,
                  let swiftCaptureRange = Range(captureRange, in: template) else {
                continue
            }
            let key = String(template[swiftCaptureRange])
            guard let value = vars[key] else {
                // Unknown key — leave the token literal.
                continue
            }
            guard let tokenRange = Range(match.range, in: result) else { continue }
            result = result.replacingCharacters(in: tokenRange, with: value)
        }
        return result
    }

    /// Return the list of variable names referenced in `template` (via
    /// `{{name}}` tokens) that are not present in `knownKeys`.
    /// The list is deduplicated and ordered by first appearance in the template.
    static func unknownVariables(in template: String, knownKeys: Set<String>) -> [String] {
        let fullRange = NSRange(location: 0, length: (template as NSString).length)
        let matches = tokenPattern.matches(in: template, range: fullRange)
        var seen = Set<String>()
        var result: [String] = []
        for match in matches {
            let captureRange = match.range(at: 1)
            guard captureRange.location != NSNotFound,
                  let swiftCaptureRange = Range(captureRange, in: template) else {
                continue
            }
            let key = String(template[swiftCaptureRange])
            guard !knownKeys.contains(key) else { continue }
            guard seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }
}
