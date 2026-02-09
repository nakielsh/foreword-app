//
//  WorkHomepageApp.swift
//  WorkHomepage
//
//  App entry. Bootstraps the GitHub token from `gh auth token` if absent,
//  then presents the first-run wizard the first time around.
//

import SwiftUI

@main
struct WorkHomepageApp: App {
    @State private var showFirstLaunchTokenPrompt: Bool = false
    @State private var showFirstRunWizard: Bool = false
    @State private var didBootstrap: Bool = false

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    await bootstrapToken()
                    await maybeShowFirstRunWizard()
                }
                .sheet(isPresented: $showFirstLaunchTokenPrompt) {
                    TokenPromptSheet(reason: .firstLaunch) {
                        showFirstLaunchTokenPrompt = false
                    }
                }
                .sheet(isPresented: $showFirstRunWizard) {
                    FirstRunWizard {
                        showFirstRunWizard = false
                    }
                }
        }

        Settings {
            SettingsView()
        }
    }

    private func bootstrapToken() async {
        if KeychainStore.get(key: "github.token") != nil {
            return
        }
        if let token = await GitHubTokenBootstrap.bootstrap() {
            KeychainStore.set(key: "github.token", value: token)
            return
        }
        // Still no token — prompt the user.
        await MainActor.run {
            showFirstLaunchTokenPrompt = true
        }
    }

    private func maybeShowFirstRunWizard() async {
        let completed = UserDefaults.standard.bool(forKey: FirstRunWizard.firstRunCompletedKey)
        guard !completed else { return }
        await MainActor.run {
            showFirstRunWizard = true
        }
    }
}
