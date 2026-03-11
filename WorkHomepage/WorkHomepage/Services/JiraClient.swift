//
//  JiraClient.swift
//  WorkHomepage
//
//  Slice 10 — Jira basic.
//
//  Thin Atlassian Cloud REST client with one method: `fetchTicket(key:)`.
//  Reads credentials from `JiraConfig` (base URL in UserDefaults, email
//  + API token in Keychain) and authenticates via HTTP Basic.
//
//  Returns a value-type `JiraTicket` with the description flattened from
//  ADF (Atlassian Document Format) to plaintext. ADF flattening is a
//  small recursive walk — we don't try to render real markdown, the LLM
//  doesn't need it.
//
//  Errors:
//    - `.notConfigured` — base URL / email / token missing. Orchestrator
//       catches and proceeds without Jira context.
//    - `.unauthorized` — 401. Surfaced so settings can prompt the user.
//    - `.ticketNotFound` — 404. Caller should treat the same as "no key
//       on the branch" (return nil from `fetchTicket`).
//    - `.http(status, body)` — other non-2xx. Orchestrator logs + drops.
//

import Foundation

struct JiraClient {

    enum JiraError: Error, Equatable {
        case notConfigured
        case unauthorized
        case http(Int, String)
        case ticketNotFound
    }

    private let session: URLSession
    private let baseURLProvider: () -> String?
    private let emailProvider: () -> String?
    private let tokenProvider: () -> String?

    init(
        session: URLSession = .shared,
        baseURLProvider: @escaping () -> String? = { JiraConfig.getBaseURL() },
        emailProvider: @escaping () -> String? = { JiraConfig.getEmail() },
        tokenProvider: @escaping () -> String? = { JiraConfig.getToken() }
    ) {
        self.session = session
        self.baseURLProvider = baseURLProvider
        self.emailProvider = emailProvider
        self.tokenProvider = tokenProvider
    }

    // MARK: - Public API

    /// Fetch a ticket by key. Returns nil for 404 (the caller treats that the
    /// same as no-key-on-branch). Throws for unauthorized, missing config, or
    /// other non-2xx HTTP responses.
    func fetchTicket(key: String) async throws -> JiraTicket? {
        guard let rawBase = baseURLProvider(), !rawBase.isEmpty,
              let email = emailProvider(), !email.isEmpty,
              let token = tokenProvider(), !token.isEmpty
        else {
            throw JiraError.notConfigured
        }

        // Strip trailing slashes so we don't end up with `//rest/...`.
        var base = rawBase
        while base.hasSuffix("/") { base.removeLast() }

        let fields = "summary,description,status,issuetype,priority,parent"
        let path = "/rest/api/3/issue/\(key)?fields=\(fields)"
        guard let url = URL(string: base + path) else {
            throw JiraError.http(0, "Invalid base URL")
        }

        let credential = "\(email):\(token)"
        guard let credData = credential.data(using: .utf8) else {
            throw JiraError.http(0, "Could not encode credentials")
        }
        let basic = "Basic " + credData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basic, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw JiraError.http(0, "No HTTP response")
        }

        switch http.statusCode {
        case 200..<300:
            return try Self.decodeTicket(data: data)
        case 401:
            throw JiraError.unauthorized
        case 404:
            throw JiraError.ticketNotFound
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw JiraError.http(http.statusCode, body)
        }
    }

    // MARK: - Decoding

    /// Decodes the Atlassian Cloud `GET /rest/api/3/issue/<key>` response.
    /// Pulled out so tests can exercise it without spinning up URLSession.
    static func decodeTicket(data: Data) throws -> JiraTicket {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JiraError.http(0, "Response is not a JSON object")
        }

        let key = json["key"] as? String ?? ""
        let fields = json["fields"] as? [String: Any] ?? [:]

        let summary = fields["summary"] as? String ?? ""

        let status: String = {
            if let s = fields["status"] as? [String: Any], let name = s["name"] as? String {
                return name
            }
            return ""
        }()

        let issueType: String = {
            if let t = fields["issuetype"] as? [String: Any], let name = t["name"] as? String {
                return name
            }
            return ""
        }()

        let priority: String? = {
            if let p = fields["priority"] as? [String: Any], let name = p["name"] as? String {
                return name.isEmpty ? nil : name
            }
            return nil
        }()

        let parentKey: String? = {
            if let parent = fields["parent"] as? [String: Any], let pk = parent["key"] as? String, !pk.isEmpty {
                return pk
            }
            return nil
        }()

        let description = flattenADF(fields["description"])

        return JiraTicket(
            key: key,
            summary: summary,
            description: description,
            status: status,
            issueType: issueType,
            priority: priority,
            parentKey: parentKey
        )
    }

    // MARK: - ADF flattening

    /// Block-level ADF nodes that should each contribute a paragraph break
    /// after their inline content. List items are blocks too — each bullet
    /// becomes its own paragraph in the flattened text.
    private static let blockTypes: Set<String> = [
        "paragraph",
        "heading",
        "blockquote",
        "codeBlock",
        "listItem",
        "bulletList",
        "orderedList",
        "rule",
        "panel",
        "mediaSingle",
        "mediaGroup"
    ]

    /// Walk an ADF document recursively, concatenating `text` fields and
    /// emitting `\n\n` between top-level paragraph / heading / list-item
    /// boundaries.
    ///
    /// `input` is whatever Foundation got back from
    /// `JSONSerialization.jsonObject` for the `description` field — most
    /// commonly a `[String: Any]` document object, but may be `NSNull` /
    /// nil / a String (legacy Wiki Markup tickets).
    static func flattenADF(_ input: Any?) -> String {
        guard let input else { return "" }
        if input is NSNull { return "" }

        // Some Jira instances still return Wiki-Markup descriptions as a
        // bare string. Surface it verbatim — better than dropping it.
        if let s = input as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }

        let raw = walk(input)

        // Collapse runs of 3+ newlines down to exactly two.
        var collapsed = raw
        while collapsed.contains("\n\n\n") {
            collapsed = collapsed.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the inline text + trailing block-break for a single node.
    private static func walk(_ node: Any) -> String {
        guard let dict = node as? [String: Any] else {
            // Unknown node shape (e.g. an array at the top of `walk` —
            // only walkChildren passes those through). Drop it.
            return ""
        }

        let type = dict["type"] as? String ?? ""

        // Leaf text node.
        if type == "text" {
            return (dict["text"] as? String) ?? ""
        }

        // hardBreak — a single newline inside a paragraph.
        if type == "hardBreak" {
            return "\n"
        }

        // mention / emoji / inlineCard — best-effort inline text fallbacks
        // so we don't drop "@john" / ":+1:" / linked card titles.
        if type == "mention" {
            if let attrs = dict["attrs"] as? [String: Any], let text = attrs["text"] as? String {
                return text
            }
            return ""
        }
        if type == "emoji" {
            if let attrs = dict["attrs"] as? [String: Any], let text = attrs["text"] as? String {
                return text
            }
            if let attrs = dict["attrs"] as? [String: Any], let shortName = attrs["shortName"] as? String {
                return shortName
            }
            return ""
        }

        let children = walkChildren(dict["content"])

        if blockTypes.contains(type) {
            // Block-level: end with a paragraph break so siblings stack
            // visibly. The outer flattenADF collapses runs of breaks.
            return children + "\n\n"
        }

        // doc, or any other container we don't specifically know about:
        // pass children through without injecting extra breaks.
        return children
    }

    /// Walk a `content` array and concatenate the result of each child.
    private static func walkChildren(_ content: Any?) -> String {
        guard let array = content as? [Any] else { return "" }
        var out = ""
        for child in array {
            out += walk(child)
        }
        return out
    }
}
