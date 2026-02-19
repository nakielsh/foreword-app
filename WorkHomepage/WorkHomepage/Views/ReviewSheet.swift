//
//  ReviewSheet.swift
//  WorkHomepage
//
//  Slice 07 — Tracer bullet end-to-end review.
//
//  Modal sheet shown when the user clicks Review on a PR. Three regions:
//   - Header: PR identity + state badge.
//   - Live stream: scrolling text view of `Review.partialStream` (auto-scrolls
//     to bottom on growth).
//   - Footer: when state is `completed`, pretty-printed raw JSON (slice 08
//     replaces this with styled findings); on `failed`/`timeout`, error
//     message; on `running`, a progress indicator.
//
//  The sheet kicks off the orchestrator on first appear (idempotent — the
//  orchestrator's single-flight gate handles repeat calls). Closing the sheet
//  does NOT cancel the run; the orchestrator finishes in the background and
//  re-opening shows the latest state.
//

import SwiftUI
import struct Foundation.Date

struct ReviewSheet: View {
    /// PR identity passed from the card. We need branch + sha to ask
    /// `WorktreeManager` to prepare a worktree; the rest is for display.
    let repo: String
    let prNumber: Int
    let prTitle: String
    let headBranch: String
    let headSha: String

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Singleton orchestrator. Slice 07 enforces single-flight via this.
    @State private var orchestrator = ReviewOrchestrator.shared

    /// Set true once we've kicked off the run for this sheet instance, so
    /// re-renders don't re-trigger.
    @State private var didKickOff: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding()
                .background(Color.gray.opacity(0.06))

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 560)
        .task {
            guard !didKickOff else { return }
            didKickOff = true
            await kickOff()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(repo)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.gray.opacity(0.18)))
                Text("#\(prNumber)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                stateBadge
            }
            Text(prTitle)
                .font(.headline)
            Text("branch: \(headBranch)  ·  sha: \(headSha.prefix(8))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var stateBadge: some View {
        let state = orchestrator.current?.state ?? "idle"
        let (label, color): (String, Color) = {
            switch state {
            case "running": return ("Running", .blue)
            case "completed": return ("Completed", .green)
            case "failed": return ("Failed", .red)
            case "timeout": return ("Timed out", .orange)
            default: return ("Idle", .gray)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let rejection = orchestrator.lastRejection, orchestrator.current == nil {
            VStack {
                Spacer()
                Text(rejection)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding()
                Spacer()
            }
        } else if let review = orchestrator.current {
            VStack(alignment: .leading, spacing: 0) {
                streamView(review: review)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if review.state == "completed" {
                    Divider()
                    rawResultView(review: review)
                        .frame(minHeight: 200, maxHeight: 320)
                } else if review.state == "failed" || review.state == "timeout" {
                    Divider()
                    errorView(review: review)
                        .frame(minHeight: 80)
                }
            }
        } else {
            VStack {
                Spacer()
                ProgressView("Preparing review…")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func streamView(review: Review) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(review.partialStream.isEmpty ? "(no output yet)" : review.partialStream)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .id("streamBottom")
                }
            }
            .onChange(of: review.partialStream) { _, _ in
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo("streamBottom", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func rawResultView(review: Review) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Raw structured result")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.top, 8)
            ScrollView {
                Text(review.rawResultJSON ?? "(no payload)")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            .background(Color.gray.opacity(0.05))
        }
    }

    @ViewBuilder
    private func errorView(review: Review) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(review.state == "timeout" ? "Timed out" : "Failed")
                    .font(.subheadline.weight(.semibold))
                Text(review.errorMessage ?? "(no error message captured)")
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.08))
    }

    // MARK: - Kick off

    private func kickOff() async {
        let store = ReviewStore(context: modelContext)
        await orchestrator.start(
            repo: repo,
            prNumber: prNumber,
            branch: headBranch,
            sha: headSha,
            store: store
        )
    }
}
