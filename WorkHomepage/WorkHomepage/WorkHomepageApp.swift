//
//  WorkHomepageApp.swift
//  WorkHomepage
//
//  App entry. Bootstraps the GitHub token from `gh auth token` if absent,
//  then presents the first-run wizard the first time around.
//
//  Slice 07 added a SwiftData container scoped to `Review` + `Finding`. The
//  container is shared by `SidebarView` (so `ReviewsTab` and the modal
//  `ReviewSheet` see the same store) and by Settings (slice 08+ may want to
//  surface review history there). Default URL — no iCloud, no special
//  configuration — keeps the data under the app's Application Support dir
//  per Apple's defaults.
//

import SwiftUI
import SwiftData

@main
struct WorkHomepageApp: App {
    @State private var showFirstLaunchTokenPrompt: Bool = false
    @State private var showFirstRunWizard: Bool = false
    @State private var didBootstrap: Bool = false

    /// Single SwiftData container backing every `@Environment(\.modelContext)`
    /// in the app. Created lazily in `init` so a misconfigured container
    /// crashes loud at launch rather than later. Failures fall back to an
    /// in-memory container so the app still launches and the UI can surface a
    /// "review persistence is broken" banner (slice 07 doesn't render that yet,
    /// but the fallback prevents a hard crash for users who have a corrupt
    /// store from an older slice).
    private let modelContainer: ModelContainer

    init() {
        let schema = Schema([Review.self, Finding.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback: in-memory store. The user's reviews won't persist
            // across launches in this state, but the app still runs.
            // swiftlint:disable:next force_try
            self.modelContainer = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }

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
        .modelContainer(modelContainer)

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
