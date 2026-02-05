//
//  DeploymentsConfig.swift
//  WorkHomepage
//
//  Slice 05: hardcoded constants for the Deployments tab.
//  Mirrors `DEPLOY_ORG`, `DEPLOY_WORKFLOW`, and `SERVICES` in index.html.
//  Settings UI for these is out of scope for this slice.
//

import Foundation

enum DeploymentsConfig {
    static let org: String = "Ala-com"
    static let workflow: String = "Deploy to EKS from ECR"

    /// Mirrors index.html SERVICES array.
    static let services: [String] = [
        "account",
        "worker",
        "rental",
        "worker_logs",
        "model_gateway",
        "worker_gateway",
        "model_catalog",
        "template",
        "rag",
        "rag_atlassian_plugin"
    ]

    /// Envs we consider known when paging — if all of these are seen, stop early.
    /// Mirrors index.html KNOWN_DEPLOY_ENVS.
    static let knownEnvs: [String] = ["prod", "dev"]

    /// Mirrors index.html `serviceToRepo`.
    static func serviceToRepo(_ service: String) -> String {
        return "backend-" + service.replacingOccurrences(of: "_", with: "-")
    }

    /// Mirrors index.html `serviceDisplayName`.
    static func serviceDisplayName(_ service: String) -> String {
        let spaced = service.replacingOccurrences(of: "_", with: " ")
        return spaced
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return first.uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }
}
