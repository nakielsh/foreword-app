//
//  ReviewSchema.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review (with slice/07-fix lenient
//  decoding).
//
//  Two responsibilities:
//   1. Codable types matching the structured JSON payload Claude returns at the
//      end of a review run. Field naming uses snake_case on the wire (matches
//      the schema published in the PRD) and camelCase in Swift, but the
//      decoder accepts a number of real-world aliases (`overallAssessment`,
//      `description`, `suggestedFix`, ...) that `claude` emits despite our
//      `--json-schema` request — that flag is best-effort, not enforced.
//   2. `Constants.reviewJSONSchema` — the JSON Schema string we hand to the
//      `claude` CLI via `--json-schema`. Lives here so the wire types and the
//      schema text stay in lockstep.
//
//  Slice 08 will reuse `ReviewSchema` to render styled findings; slice 07 only
//  uses it to (a) decode the final result for persistence into `Review` /
//  `Finding` rows, and (b) display the same payload pretty-printed in the modal.
//

import Foundation

/// Top-level decode shape for Claude's structured review result.
///
/// All fields are decoded permissively. `verdict` is optional — claude
/// sometimes omits it entirely. `jiraAlignment` is optional, and `positives`
/// is accepted (claude likes emitting them) even though slice 07 doesn't
/// render them.
struct ReviewSchema: Codable, Hashable {
    let summary: String
    /// `"approve" | "request_changes" | "comment" | "needsWork" | …`. Kept as
    /// a String to stay permissive against future schema additions; the UI
    /// maps it to a tag. Decoded from `verdict` OR `overallAssessment`.
    let verdict: String?
    let findings: [SchemaFinding]
    let jiraAlignment: JiraAlignment?
    /// Free-form positives list claude likes to include. Stored verbatim so
    /// later slices can render it; slice 07 ignores it.
    let positives: [String]?

    private enum CodingKeys: String, CodingKey {
        case summary
        case verdict
        case overallAssessment
        case findings
        case jiraAlignment = "jira_alignment"
        case positives
    }

    init(
        summary: String,
        verdict: String?,
        findings: [SchemaFinding],
        jiraAlignment: JiraAlignment? = nil,
        positives: [String]? = nil
    ) {
        self.summary = summary
        self.verdict = verdict
        self.findings = findings
        self.jiraAlignment = jiraAlignment
        self.positives = positives
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `summary` is the only truly-required field. If claude omits it,
        // we synthesize an empty one rather than failing — the orchestrator
        // already records the raw payload.
        self.summary = (try? container.decode(String.self, forKey: .summary)) ?? ""

        // Verdict aliases: `verdict` first (canonical), fall back to
        // `overallAssessment` (real claude output).
        if let v = try? container.decodeIfPresent(String.self, forKey: .verdict) {
            self.verdict = v
        } else if let oa = try? container.decodeIfPresent(String.self, forKey: .overallAssessment) {
            self.verdict = oa
        } else {
            self.verdict = nil
        }

        self.findings = (try? container.decodeIfPresent([SchemaFinding].self, forKey: .findings)) ?? []
        self.jiraAlignment = try? container.decodeIfPresent(JiraAlignment.self, forKey: .jiraAlignment)
        self.positives = try? container.decodeIfPresent([String].self, forKey: .positives)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(summary, forKey: .summary)
        try container.encodeIfPresent(verdict, forKey: .verdict)
        try container.encode(findings, forKey: .findings)
        try container.encodeIfPresent(jiraAlignment, forKey: .jiraAlignment)
        try container.encodeIfPresent(positives, forKey: .positives)
    }
}

/// One issue/observation in the review payload. Mirrored 1:1 to a `Finding`
/// SwiftData row by `ReviewStore.markCompleted`.
///
/// Decoder accepts the canonical (`message`, `suggestion`) and the real-world
/// claude (`description`, `suggestedFix`) field names. `category` is captured
/// when present but is informational only.
struct SchemaFinding: Codable, Hashable {
    /// Raw severity string from claude (kept verbatim for display fidelity).
    /// Use `normalizedSeverity` to map to our 5-bucket vocabulary.
    let severity: String
    let file: String
    /// 1-based line where the finding starts.
    let line: Int
    /// Optional 1-based end line for multi-line findings.
    let endLine: Int?
    /// One-line headline.
    let title: String
    /// 1-3 sentence description. Decoded from `message` OR `description`.
    let message: String
    /// Optional code-level suggestion. Decoded from `suggestion` OR
    /// `suggestedFix`.
    let suggestion: String?
    /// Optional informational category (e.g. `security`, `style`, `bug`).
    /// Claude emits this; we surface it for slice 08 grouping.
    let category: String?

    private enum CodingKeys: String, CodingKey {
        case severity
        case file
        case line
        case endLine
        case title
        case issue
        case message
        case description
        case explanation
        case suggestion
        case suggestedFix
        case category
    }

    init(
        severity: String,
        file: String,
        line: Int,
        endLine: Int? = nil,
        title: String,
        message: String,
        suggestion: String? = nil,
        category: String? = nil
    ) {
        self.severity = severity
        self.file = file
        self.line = line
        self.endLine = endLine
        self.title = title
        self.message = message
        self.suggestion = suggestion
        self.category = category
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.severity = (try? container.decodeIfPresent(String.self, forKey: .severity)) ?? ""
        self.file = (try? container.decodeIfPresent(String.self, forKey: .file)) ?? ""
        self.line = (try? container.decodeIfPresent(Int.self, forKey: .line)) ?? 0
        self.endLine = try? container.decodeIfPresent(Int.self, forKey: .endLine)

        if let t = try? container.decodeIfPresent(String.self, forKey: .title), !t.isEmpty {
            self.title = t
        } else if let i = try? container.decodeIfPresent(String.self, forKey: .issue), !i.isEmpty {
            self.title = i
        } else {
            self.title = ""
        }

        if let m = try? container.decodeIfPresent(String.self, forKey: .message), !m.isEmpty {
            self.message = m
        } else if let d = try? container.decodeIfPresent(String.self, forKey: .description), !d.isEmpty {
            self.message = d
        } else if let e = try? container.decodeIfPresent(String.self, forKey: .explanation), !e.isEmpty {
            self.message = e
        } else {
            self.message = ""
        }

        if let s = try? container.decodeIfPresent(String.self, forKey: .suggestion) {
            self.suggestion = s
        } else if let sf = try? container.decodeIfPresent(String.self, forKey: .suggestedFix) {
            self.suggestion = sf
        } else {
            self.suggestion = nil
        }

        self.category = try? container.decodeIfPresent(String.self, forKey: .category)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(severity, forKey: .severity)
        try container.encode(file, forKey: .file)
        try container.encode(line, forKey: .line)
        try container.encodeIfPresent(endLine, forKey: .endLine)
        try container.encode(title, forKey: .title)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(suggestion, forKey: .suggestion)
        try container.encodeIfPresent(category, forKey: .category)
    }

    /// Map known severity synonyms to our 5-bucket vocabulary
    /// (`blocker | major | minor | nit | praise`). Unknown values are returned
    /// unchanged so the UI can still display whatever claude said.
    var normalizedSeverity: String {
        switch severity.lowercased() {
        case "blocker", "critical":                  return "blocker"
        case "major", "high":                        return "major"
        case "minor", "medium":                      return "minor"
        case "nit", "low", "info",
             "nitpick", "suggestion":                return "nit"
        case "praise":                               return "praise"
        default:                                     return severity
        }
    }
}

/// Jira alignment notes when Jira context is supplied to the prompt. Slice 07
/// never supplies Jira, so this is generally nil/absent in practice.
struct JiraAlignment: Codable, Hashable {
    /// `true` when Claude believes the diff implements the ticket; `false` when
    /// it diverges. Permissively `Bool?` — Claude may decline to answer.
    let matchesTicket: Bool?
    /// Free-form notes explaining the alignment call.
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case matchesTicket = "matches_ticket"
        case notes
    }
}

// MARK: - JSON Schema string for `claude --json-schema`

/// Constants used by the review pipeline. Held in an enum namespace so it's
/// `Constants.reviewJSONSchema` at the call site, which is greppable.
enum Constants {

    /// JSON Schema (draft-2020-12) handed to `claude -p ... --json-schema <this>`.
    /// Mirrors `ReviewSchema` 1:1 — keep them in sync. Stored as a single literal
    /// string so we can pass it straight to the CLI without round-tripping
    /// through Foundation's JSON encoder, which would re-order keys.
    ///
    /// In practice claude treats `--json-schema` as guidance, not strict
    /// validation, so the Swift decoder must be more permissive than this
    /// schema — see the custom `init(from:)` implementations above.
    static let reviewJSONSchema: String = """
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "type": "object",
      "additionalProperties": false,
      "required": ["summary", "verdict", "findings"],
      "properties": {
        "summary": { "type": "string" },
        "verdict": {
          "type": "string",
          "enum": ["approve", "request_changes", "comment"]
        },
        "findings": {
          "type": "array",
          "items": {
            "type": "object",
            "additionalProperties": false,
            "required": ["severity", "file", "line", "title", "message"],
            "properties": {
              "severity": {
                "type": "string",
                "enum": ["blocker", "major", "minor", "nit", "praise"]
              },
              "file": { "type": "string" },
              "line": { "type": "integer", "minimum": 1 },
              "endLine": { "type": ["integer", "null"], "minimum": 1 },
              "title": { "type": "string" },
              "message": { "type": "string" },
              "suggestion": { "type": ["string", "null"] }
            }
          }
        },
        "jira_alignment": {
          "type": ["object", "null"],
          "additionalProperties": false,
          "properties": {
            "matches_ticket": { "type": ["boolean", "null"] },
            "notes": { "type": ["string", "null"] }
          }
        }
      }
    }
    """
}
