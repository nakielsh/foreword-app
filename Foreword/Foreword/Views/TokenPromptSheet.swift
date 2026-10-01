//
//  TokenPromptSheet.swift
//  Foreword
//
//  Sheet shown on first launch when no token is found, and on 401 re-auth.
//

import SwiftUI

struct TokenPromptSheet: View {
    enum Reason {
        case firstLaunch
        case reauth

        var headline: String {
            switch self {
            case .firstLaunch: return "GitHub token required"
            case .reauth: return "Re-auth required"
            }
        }

        var detail: String {
            switch self {
            case .firstLaunch:
                return "We couldn't auto-fetch a token from gh. Paste a personal access token to continue."
            case .reauth:
                return "GitHub returned 401. Paste a fresh personal access token to continue."
            }
        }
    }

    let reason: Reason
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var token: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(reason.headline)
                .font(Font.display(size: 20, weight: .bold))
                .foregroundStyle(Color.textPrimary)
            Text(reason.detail)
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textSecondary)

            SecureField("ghp_… or github_pat_…", text: $token)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    KeychainStore.set(key: "github.token", value: trimmed)
                    onSaved()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
