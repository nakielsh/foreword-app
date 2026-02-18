//
//  ReviewSchema.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Two responsibilities:
//   1. Codable types matching the structured JSON payload Claude returns at the
//      end of a review run. Field naming uses snake_case on the wire (matches the
//      schema published in the PRD and slice 07 spec) and camelCase in Swift.
//   2. `Constants.reviewJSONSchema` — the JSON Schema string we hand to the
//      `claude` CLI via `--json-schema`. Lives here so the wire types and the
//      schema text stay in lockstep (any drift is a one-file change).
//
//  Slice 08 will reuse `ReviewSchema` to render styled findings; slice 07 only
//  uses it to (a) decode the final result for persistence into `Review` /
//  `Finding` rows, and (b) display the same payload pretty-printed in the modal.
//

import Foundation

/// Top-level decode shape for Claude's structured review result.
///
/// `jiraAlignment` is optional (and slice 07 never sends Jira context, so it
/// will typically be nil/absent). When present, fields inside it are also
/// optional — Claude may return only `notes` if `matches_ticket` couldn't be
/// determined.
struct ReviewSchema: Codable, Hashable {
    let summary: String
    /// `"approve" | "request_changes" | "comment"`. Kept as a String to stay
    /// permissive against future schema additions; the UI maps it to a tag.
    let verdict: String
    let findings: [SchemaFinding]
    let jiraAlignment: JiraAlignment?

    enum CodingKeys: String, CodingKey {
        case summary
        case verdict
        case findings
        case jiraAlignment = "jira_alignment"
    }
}

/// One issue/observation in the review payload. Mirrored 1:1 to a `Finding`
/// SwiftData row by `ReviewStore.markCompleted`.
struct SchemaFinding: Codable, Hashable {
    /// `blocker | major | minor | nit | praise`.
    let severity: String
    let file: String
    /// 1-based line where the finding starts.
    let line: Int
    /// Optional 1-based end line for multi-line findings.
    let endLine: Int?
    /// One-line headline.
    let title: String
    /// 1-3 sentence description.
    let message: String
    /// Optional code-level suggestion. Permissively typed as a String — Claude
    /// may emit it as a multi-line block.
    let suggestion: String?

    enum CodingKeys: String, CodingKey {
        case severity
        case file
        case line
        case endLine
        case title
        case message
        case suggestion
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
