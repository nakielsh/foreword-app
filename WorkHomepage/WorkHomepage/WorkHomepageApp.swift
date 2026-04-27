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

    /// Slice 19 — appearance preference read reactively from UserDefaults so
    /// `.preferredColorScheme` re-evaluates whenever the Settings picker changes.
    @AppStorage(AppSettings.appearanceKey) private var appearanceRaw: String = Appearance.system.rawValue

    private var appearance: Appearance {
        Appearance(rawValue: appearanceRaw) ?? .system
    }

    /// Single SwiftData container backing every `@Environment(\.modelContext)`
    /// in the app. Created lazily in `init` so a misconfigured container
    /// crashes loud at launch rather than later. Failures fall back to an
    /// in-memory container so the app still launches and the UI can surface a
    /// "review persistence is broken" banner (slice 07 doesn't render that yet,
    /// but the fallback prevents a hard crash for users who have a corrupt
    /// store from an older slice).
    private let modelContainer: ModelContainer

    init() {
        // Slice 12: `CachedJiraTicket` joins the schema so the cache shares the
        // same on-disk store as reviews + findings. New `@Model` types must be
        // listed here or `ModelContainer(for:)` won't see them and queries
        // against the type at runtime will throw.
        // Slice 24: `PreReviewSummary` added — lightweight 3-bullet TL;DR cache.
        let schema = Schema([Review.self, Finding.self, CachedJiraTicket.self, PreReviewSummary.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Fallback: in-memory store. The user's reviews won't persist
            // across launches in this state, but the app still runs. Log loud
            // so the silent persistence loss is visible in Console.
            FileHandle.standardError.write(Data("[WorkHomepage] FATAL: on-disk SwiftData container failed to load — falling back to in-memory store. Reviews and summaries will NOT persist across launches. Error: \(error)\n".utf8))
            // swiftlint:disable:next force_try
            self.modelContainer = try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
        // Slice 16: instantiate the menu-bar counts singleton at launch so it
        // starts observing `ReviewOrchestrator` and `NotificationCenter`
        // before the user can interact with anything.
        _ = MenuBarCounts.shared
    }

    var body: some Scene {
        WindowGroup(id: MenuBarWindowID.main) {
            SidebarView()
                .frame(minWidth: 800, minHeight: 500)
                .preferredColorScheme(appearance.colorScheme)
                .task {
                    guard !didBootstrap else { return }
                    didBootstrap = true
                    await bootstrapToken()
                    await maybeShowFirstRunWizard()
                    await refreshLocalRepoIndex()
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

        // Slice 16: at-a-glance counts in the system menu bar. The label
        // reads `MenuBarCounts.shared` directly, so no parameters needed.
        MenuBarExtra {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
    }

    private func bootstrapToken() async {
        if KeychainStore.get(key: "github.token") != nil {
            return
        }
        // Consent gate: do NOT silently shell out to `gh auth token` on
        // first launch. The first-run wizard now owns that path — its
        // GitHub section explains what the bootstrap does and only fires
        // it when the user clicks "Try gh auth token". For users who
        // already finished the wizard but somehow ended up tokenless
        // (cleared keychain, fresh sandbox container, etc.), fall through
        // to the existing `TokenPromptSheet` so they can paste a token.
        let firstRunDone = UserDefaults.standard.bool(forKey: FirstRunWizard.firstRunCompletedKey)
        if firstRunDone {
            await MainActor.run {
                showFirstLaunchTokenPrompt = true
            }
        }
        // If the wizard hasn't run yet, `maybeShowFirstRunWizard` will
        // present it; the wizard's GitHub section drives the consented
        // bootstrap path.
    }

    /// Walks the configured search roots (default `~/src`) and refreshes the
    /// `<org>/<repo>` → local-clone mapping in the background. Keeps the
    /// IntelliJ launcher's synchronous `WorktreePath.url` lookup fast since
    /// the mapping is already populated by the time the user clicks a
    /// finding.
    private func refreshLocalRepoIndex() async {
        await Task.detached(priority: .background) {
            LocalRepoIndex.rescan()
        }.value
    }

    private func maybeShowFirstRunWizard() async {
        let completed = UserDefaults.standard.bool(forKey: FirstRunWizard.firstRunCompletedKey)
        guard !completed else { return }
        await MainActor.run {
            showFirstRunWizard = true
        }
    }
}
