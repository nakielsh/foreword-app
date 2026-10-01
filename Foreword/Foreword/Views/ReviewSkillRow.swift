//
//  ReviewSkillRow.swift
//  Foreword
//
//  Status + Install button for the bundled `reviewing-pr-final-state`
//  Claude Code skill the default review prompt relies on. Shared by the
//  first-run wizard and Settings.
//

import SwiftUI

struct ReviewSkillRow: View {

    @State private var isInstalled = BundledSkillInstaller.isInstalled(BundledSkillInstaller.reviewSkillName)
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(isInstalled ? Color.accentFern : Color.accentTerracotta)
                    .frame(width: 10, height: 10)
                Text("skill")
                    .frame(width: 60, alignment: .leading)
                    .font(.body.monospaced())
                Text(isInstalled ? "~/.claude/skills/\(BundledSkillInstaller.reviewSkillName)" : "not installed")
                    .font(.callout.monospaced())
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if !isInstalled {
                    Button("Install") { install() }
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(Font.appBody(size: 11))
                    .foregroundStyle(Color.accentTerracotta)
            }
            Text("Reviews use the `\(BundledSkillInstaller.reviewSkillName)` skill to scope findings to what the PR actually changes. Foreword ships a copy; installing never overwrites an existing one.")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func install() {
        switch BundledSkillInstaller.install() {
        case .installed, .alreadyPresent:
            isInstalled = true
            errorMessage = nil
        case .failed(let message):
            errorMessage = message
        }
    }
}
