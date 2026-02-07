//
//  DeploysTab.swift
//  WorkHomepage
//
//  Slice 05: parity port of the index.html Deployments tab.
//
//  - One card per service in `DeploymentsConfig.services`.
//  - Skeleton cards render immediately; each fills as its async fetch
//    resolves so slow services don't block the rest.
//  - For each service we fetch workflow runs for the named workflow and
//    pick the latest run per env (prod / dev) using `DeploymentsParser`.
//

import SwiftUI
import Foundation

struct DeploysTab: View {
    /// Bumped by SidebarView's toolbar Refresh button. Defaulted to 0 so the
    /// existing `DeploysTab()` call site in SidebarView continues to compile;
    /// when SidebarView is rewired to pass `refreshTick`, this tab will pick
    /// up changes via `.onChange` like ReviewsTab.
    let refreshTick: Int

    init(refreshTick: Int = 0) {
        self.refreshTick = refreshTick
    }

    @State private var serviceStates: [String: ServiceCardState] = [:]
    @State private var globalError: String?
    @State private var hasRefreshedOnce: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let globalError {
                ErrorBanner(message: globalError)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Deploys")
        .onChange(of: refreshTick) { _, _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !hasRefreshedOnce {
            VStack {
                Spacer()
                Text("Click Refresh to load deployments.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(DeploymentsConfig.services, id: \.self) { service in
                        let state = serviceStates[service] ?? .loading
                        DeployCard(service: service, state: state)
                    }
                }
                .padding()
            }
        }
    }

    @MainActor
    private func refresh() async {
        globalError = nil
        hasRefreshedOnce = true

        // Reset all to loading immediately so skeletons appear.
        var initial: [String: ServiceCardState] = [:]
        for service in DeploymentsConfig.services {
            initial[service] = .loading
        }
        serviceStates = initial

        // Fire all fetches concurrently. Each card fills independently.
        await withTaskGroup(of: (String, ServiceCardState).self) { group in
            for service in DeploymentsConfig.services {
                group.addTask {
                    let result = await fetchOne(service: service)
                    return (service, result)
                }
            }
            for await (service, state) in group {
                serviceStates[service] = state
                if case .unauthorized = state {
                    globalError = "GitHub returned 401. Please re-enter your token."
                }
            }
        }
    }

    /// Fetches workflow runs for one service and reduces them into a card state.
    private func fetchOne(service: String) async -> ServiceCardState {
        let repo = DeploymentsConfig.serviceToRepo(service)
        let client = GitHubClient()
        do {
            let runs = try await client.fetchWorkflowRuns(
                repo: repo,
                workflow: DeploymentsConfig.workflow,
                perPage: 100,
                pages: 2
            )

            // Reduce to one Deployment per env (latest by createdAt).
            var byEnv: [String: Deployment] = [:]
            for run in runs {
                guard let parsed = DeploymentsParser.parse(runName: run.name) else { continue }
                let deployment = Deployment(
                    env: parsed.env,
                    version: parsed.version,
                    runName: run.name,
                    createdAt: run.createdAt,
                    htmlURL: run.htmlURL,
                    conclusion: run.conclusion
                )
                if let existing = byEnv[parsed.env] {
                    if deployment.createdAt > existing.createdAt {
                        byEnv[parsed.env] = deployment
                    }
                } else {
                    byEnv[parsed.env] = deployment
                }
            }
            let deployments = Array(byEnv.values)
            return .loaded(deployments)
        } catch GitHubError.unauthorized {
            return .unauthorized
        } catch GitHubError.missingToken {
            return .error("No GitHub token stored.")
        } catch GitHubError.http(let status, _) {
            return .error("GitHub error \(status).")
        } catch GitHubError.decoding(let detail) {
            return .error("Decode failed: \(detail)")
        } catch GitHubError.transport(let detail) {
            return .error("Network error: \(detail)")
        } catch {
            return .error("Unexpected: \(error.localizedDescription)")
        }
    }
}

// MARK: - Card state

private enum ServiceCardState {
    case loading
    case loaded([Deployment])
    case unauthorized
    case error(String)
}

// MARK: - Subviews

private struct DeployCard: View {
    let service: String
    let state: ServiceCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(DeploymentsConfig.serviceDisplayName(service))
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.08))
        )
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Loading runs…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .loaded(let deployments):
            if deployments.isEmpty {
                Text("No recent deployments found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let sorted = deployments.sorted { lhs, rhs in
                    envOrder(lhs.env) < envOrder(rhs.env)
                }
                ForEach(sorted, id: \.env) { d in
                    DeployRow(deployment: d)
                }
            }
        case .unauthorized:
            Text("401 — re-auth required")
                .font(.subheadline)
                .foregroundStyle(.orange)
        case .error(let msg):
            Text(msg)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func envOrder(_ env: String) -> Int {
        switch env {
        case "prod": return 0
        case "staging": return 1
        case "dev": return 2
        default: return 3
        }
    }
}

private struct DeployRow: View {
    let deployment: Deployment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(deployment.env.uppercased())
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(envColor.opacity(0.18))
                .foregroundStyle(envColor)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(deployment.version)
                .font(.subheadline.monospaced())
            Text(deployment.isSnapshot ? "snapshot" : "release")
                .font(.caption2)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
                .foregroundStyle(.secondary)
            Spacer()
            Text(relativeTime(from: deployment.createdAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("View run", destination: deployment.htmlURL)
                .font(.caption)
        }
    }

    private var envColor: Color {
        switch deployment.env {
        case "prod": return .green
        case "staging": return .blue
        case "dev": return .orange
        default: return .gray
        }
    }

    private func relativeTime(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct ErrorBanner: View {
    let message: String
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
