//
//  ReviewsTab.swift
//  WorkHomepage
//
//  Slice 01: title-only PR cards for review-requested:@me.
//  Refresh is driven by the global toolbar button (refreshTick prop).
//

import SwiftUI

struct ReviewsTab: View {
    let refreshTick: Int

    @State private var prs: [PullRequest] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showReauthSheet: Bool = false
    @State private var hasFetchedOnce: Bool = false

    private let client = GitHubClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let errorMessage {
                ErrorBanner(message: errorMessage)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Reviews")
        .onChange(of: refreshTick) { _, _ in
            Task { await refresh() }
        }
        .sheet(isPresented: $showReauthSheet) {
            TokenPromptSheet(reason: .reauth) {
                showReauthSheet = false
                Task { await refresh() }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && prs.isEmpty {
            ProgressView("Loading review-requested PRs…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasFetchedOnce {
            EmptyHint(text: "Click Refresh to load review-requested PRs.")
        } else if prs.isEmpty {
            EmptyHint(text: "No PRs awaiting your review.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(prs) { pr in
                        PRCard(pr: pr)
                    }
                }
                .padding()
            }
        }
    }

    @MainActor
    private func refresh() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await client.fetchReviewRequestedPRs()
            prs = result
            hasFetchedOnce = true
        } catch GitHubError.unauthorized {
            errorMessage = "GitHub returned 401. Please re-enter your token."
            prs = []
            showReauthSheet = true
        } catch GitHubError.missingToken {
            errorMessage = "No GitHub token stored. Add one to continue."
            showReauthSheet = true
        } catch GitHubError.http(let status, _) {
            errorMessage = "GitHub error \(status)."
        } catch GitHubError.decoding(let detail) {
            errorMessage = "Failed to decode GitHub response: \(detail)"
        } catch GitHubError.transport(let detail) {
            errorMessage = "Network error: \(detail)"
        } catch {
            errorMessage = "Unexpected error: \(error.localizedDescription)"
        }
    }
}

private struct PRCard: View {
    let pr: PullRequest

    var body: some View {
        Link(destination: pr.htmlURL) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pr.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    Text(pr.repoFullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("@\(pr.user.login)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("#\(pr.number)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
