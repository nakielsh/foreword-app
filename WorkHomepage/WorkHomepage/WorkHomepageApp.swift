//
//  WorkHomepageApp.swift
//  WorkHomepage
//
//  App entry. Bootstraps the GitHub token from `gh auth token` if absent.
//

import SwiftUI

@main
struct WorkHomepageApp: App {
    @State private var showFirstLaunchTokenPrompt: Bool = false
    @State private var didBootstrap: Bool = false

    var body: some Scene {
        WindowGroup {
            SidebarView()
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    await bootstrapToken()
                }
                .sheet(isPresented: $showFirstLaunchTokenPrompt) {
                    TokenPromptSheet(reason: .firstLaunch) {
                        showFirstLaunchTokenPrompt = false
                    }
                }
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
}
