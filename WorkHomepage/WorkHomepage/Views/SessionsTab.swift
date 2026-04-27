//
//  SessionsTab.swift
//  WorkHomepage
//
//  Slice 04: native Claude Code sessions tab.
//  Reads `~/.claude/sessions/*.json` on demand via SessionsReader.
//
//  Note on refresh: SidebarView calls `SessionsTab()` without parameters today.
//  We accept `refreshTick` with a default value so the existing call site keeps
//  compiling (the global toolbar refresh button cannot be wired here without
//  modifying SidebarView, which slice 04 forbids). A local "Refresh" button
//  inside the tab covers the user-facing acceptance criterion.
//

import SwiftUI

struct SessionsTab: View {
    let refreshTick: Int

    @State private var sessions: [Session] = []
    @State private var hasFetchedOnce: Bool = false
    @State private var isLoading: Bool = false

    init(refreshTick: Int = 0) {
        self.refreshTick = refreshTick
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Sessions")
        .onAppear {
            if !hasFetchedOnce {
                refresh()
            }
        }
        .onChange(of: refreshTick) { _, _ in
            refresh()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            let cliCount = sessions.filter { $0.entrypoint == "cli" }.count
            let vscodeCount = sessions.count - cliCount

            StatChip(label: "CLI", value: cliCount, accent: .accentFern)
            if vscodeCount > 0 {
                StatChip(label: "VS Code", value: vscodeCount, accent: .accentMarigold)
            }
            StatChip(label: "total", value: sessions.count, accent: .textMuted)

            Spacer()

            Button {
                refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
            .help("Re-read ~/.claude/sessions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.bgSurface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading && sessions.isEmpty {
            ProgressView("Reading sessions…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sessions.isEmpty {
            EmptyState()
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(sessions) { session in
                        SessionCard(session: session)
                    }
                }
                .padding()
            }
            .background(Color.bgDeep)
        }
    }

    // MARK: - Actions

    private func refresh() {
        isLoading = true
        // `SessionsReader.currentSessions()` reads `~/.claude/sessions/*.json`
        // and `~/.claude/history.jsonl` synchronously. With long history
        // files (active multi-day Claude users) this is hundreds of ms of
        // disk I/O — would freeze the UI on the main actor. Hop off main
        // for the read, hop back on for the state mutation.
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                SessionsReader.currentSessions()
            }.value
            sessions = result
            hasFetchedOnce = true
            isLoading = false
        }
    }
}

// MARK: - Card

private struct SessionCard: View {
    let session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            topRow
            cwdRow
            if let context = displayContext {
                Text(context)
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            metaRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.bgCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.borderSubtle, lineWidth: 1)
        )
    }

    private var isVscode: Bool { session.entrypoint != "cli" }

    private var displayContext: String? {
        if !session.name.isEmpty { return session.name }
        if let prompt = session.lastPrompt, !prompt.isEmpty { return prompt }
        return nil
    }

    @ViewBuilder
    private var topRow: some View {
        HStack(spacing: 8) {
            EntrypointBadge(isVscode: isVscode)
            Spacer()
            Text("running \(durationSince(epochMs: session.startedAt))")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textSecondary)
        }
    }

    @ViewBuilder
    private var cwdRow: some View {
        let parts = PathFormatter.abbreviateHome(session.cwd)
        HStack(spacing: 0) {
            if !parts.prefix.isEmpty {
                Text(parts.prefix)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(parts.rest)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("PID")
                    .font(Font.appBody(size: 11))
                    .foregroundStyle(Color.textMuted)
                Text("\(session.pid)")
                    .font(Font.mono(size: 11))
                    .foregroundStyle(Color.textSecondary)
            }
            Text("Started \(formatStart(epochMs: session.startedAt))")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
        }
    }
}

// MARK: - Subviews

private struct EntrypointBadge: View {
    let isVscode: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isVscode ? "chevron.left.forwardslash.chevron.right" : "terminal")
                .imageScale(.small)
            Text(isVscode ? "VS Code" : "Terminal")
                .font(Font.appBody(size: 11))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(badgeColor(isVscode: isVscode).opacity(0.15))
        )
        .foregroundStyle(badgeColor(isVscode: isVscode))
    }

    private func badgeColor(isVscode: Bool) -> Color {
        isVscode ? Color.accentMarigold : Color.accentFern
    }
}

private struct StatChip: View {
    let label: String
    let value: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 6, height: 6)
            Text("\(value)")
                .font(Font.appBody(size: 13, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(label)
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(Color.borderSubtle)
        )
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No sessions found")
                .font(Font.appBody(size: 15))
                .foregroundStyle(Color.textMuted)
            Text("Start a Claude Code session, then click Refresh.")
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Formatting helpers

/// Mirrors `durationSince` in index.html.
private func durationSince(epochMs: Int) -> String {
    let nowMs = Int(Date().timeIntervalSince1970 * 1000)
    let diffMs = max(0, nowMs - epochMs)
    let mins = diffMs / 60_000
    let hours = mins / 60
    let days = hours / 24
    if days > 0 { return "\(days)d \(hours % 24)h" }
    if hours > 0 { return "\(hours)h \(mins % 60)m" }
    return "\(mins)m"
}

private func formatStart(epochMs: Int) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
    let fmt = DateFormatter()
    fmt.dateFormat = "MMM d, HH:mm"
    return fmt.string(from: date)
}
