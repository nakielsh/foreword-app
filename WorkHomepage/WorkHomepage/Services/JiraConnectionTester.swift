//
//  JiraConnectionTester.swift
//  WorkHomepage
//
//  Slice 06 helper that pings `<baseURL>/rest/api/3/myself` with basic auth.
//  Used by the SettingsView "Test connection" button. The real JiraClient
//  ships in slice 10; this is a one-shot health check, not a client.
//

import Foundation

enum JiraConnectionTester {
    enum Result: Equatable {
        case ok
        case failed(String)
    }

    static func test(baseURL: String, email: String, token: String) async -> Result {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedBase.isEmpty else { return .failed("Base URL is empty") }
        guard !trimmedEmail.isEmpty else { return .failed("Email is empty") }
        guard !trimmedToken.isEmpty else { return .failed("Token is empty") }

        // Strip trailing slashes so we don't end up with `//rest/...`.
        var base = trimmedBase
        while base.hasSuffix("/") { base.removeLast() }

        guard let url = URL(string: base + "/rest/api/3/myself") else {
            return .failed("Invalid base URL")
        }

        let credential = "\(trimmedEmail):\(trimmedToken)"
        guard let credData = credential.data(using: .utf8) else {
            return .failed("Could not encode credentials")
        }
        let basic = "Basic " + credData.base64EncodedString()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basic, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failed("No HTTP response")
            }
            if (200..<300).contains(http.statusCode) {
                return .ok
            } else {
                // Surface a body snippet so "valid creds, wrong tenant" is
                // diagnosable. Atlassian's 401 typically returns an HTML
                // login page or a JSON error body — either way, the first
                // ~200 chars uniquely identify the failure mode (auth vs.
                // captcha-required vs. wrong cloud-id).
                let snippet = bodySnippet(from: data, limit: 200)
                if snippet.isEmpty {
                    return .failed("HTTP \(http.statusCode)")
                }
                return .failed("HTTP \(http.statusCode): \(snippet)")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Returns up to `limit` characters from the response body, collapsing
    /// runs of whitespace so HTML login pages don't dominate the message
    /// with newlines and indentation. Returns `""` if `data` is empty or
    /// not UTF-8 decodable — the caller falls back to the bare HTTP code.
    private static func bodySnippet(from data: Data, limit: Int) -> String {
        guard !data.isEmpty, let raw = String(data: data, encoding: .utf8) else {
            return ""
        }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
