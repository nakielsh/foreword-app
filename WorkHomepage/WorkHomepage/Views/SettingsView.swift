//
//  SettingsView.swift
//  WorkHomepage
//
//  App-wide settings exposed via the macOS Settings menu (`Cmd-,`).
//  Mirrors the first-run wizard but always available, and adds re-detect /
//  re-paste-token controls.
//

import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    // GitHub
    @State private var hasGitHubToken: Bool = false
    @State private var isReDetectingGitHub: Bool = false

    // Jira
    @State private var jiraBaseURL: String = ""
    @State private var jiraEmail: String = ""
    @State private var jiraToken: String = ""
    @State private var jiraTestStatus: TestStatus = .idle
    @State private var jiraTesting: Bool = false

    // Tools
    @State private var toolStatus: [Tool: ResolverStatus] = [:]

    // Behavior
    @State private var concurrencyCap: Int = AppSettings.concurrencyCapDefault
    @State private var prefixesText: String = ""

    // Appearance (slice 19)
    @AppStorage(AppSettings.appearanceKey) private var appearanceRaw: String = Appearance.system.rawValue

    // Sheets
    @State private var showRePasteTokenSheet: Bool = false
    @State private var showWizardSheet: Bool = false

    // Jira cache (slice 12)
    @State private var showClearJiraCacheConfirm: Bool = false
    @State private var jiraCacheClearing: Bool = false
    @State private var jiraCacheStatus: String? = nil

    @Environment(\.modelContext) private var modelContext

    // Storage / disk usage (slice 17)
    @State private var totalDiskBytes: Int64 = 0
    @State private var perRepoUsage: [WorktreeManager.RepoUsage] = []
    @State private var isComputingSizes: Bool = false
    @State private var pendingEvictRepo: String? = nil
    @State private var evictError: String? = nil

    @Environment(\.dismiss) private var dismiss

    enum TestStatus: Equatable {
        case idle
        case ok
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                gitHubSection
                Divider()
                jiraSection
                Divider()
                toolsSection
                Divider()
                behaviorSection
                Divider()
                appearanceSection
                Divider()
                storageSection
                Divider()
                wizardSection

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                    Button("Save") { save(); dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 8)
            }
            .padding(20)
            .frame(minWidth: 520, idealWidth: 560)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 720)
        .onAppear { loadAll() }
        .sheet(isPresented: $showRePasteTokenSheet) {
            TokenPromptSheet(reason: .reauth) {
                showRePasteTokenSheet = false
                hasGitHubToken = (KeychainStore.get(key: "github.token") != nil)
            }
        }
        .sheet(isPresented: $showWizardSheet) {
            FirstRunWizard(onFinished: {
                showWizardSheet = false
                loadAll()
            })
        }
    }

    // MARK: - Sections

    private var gitHubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GitHub").font(.headline)
            HStack {
                Circle()
                    .fill(hasGitHubToken ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(hasGitHubToken ? "Token saved in Keychain" : "No token in Keychain")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Re-paste token") { showRePasteTokenSheet = true }
                Button("Re-detect from gh") {
                    Task { await reDetectFromGh() }
                }
                .disabled(isReDetectingGitHub)
                if isReDetectingGitHub { ProgressView().controlSize(.small) }
            }
        }
    }

    private var jiraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Jira").font(.headline)
            TextField("Base URL (e.g. https://acme.atlassian.net)", text: $jiraBaseURL)
                .textFieldStyle(.roundedBorder)
            TextField("Email", text: $jiraEmail)
                .textFieldStyle(.roundedBorder)
            SecureField("API token", text: $jiraToken)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Test connection") {
                    Task { await testJira() }
                }
                .disabled(jiraTesting || jiraBaseURL.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty)
                if jiraTesting { ProgressView().controlSize(.small) }
                jiraStatusLabel
            }
            // Slice 12 — Clear cache button. The full confirm dialog is
            // defined as a `.confirmationDialog` modifier on the section so
            // the role-destructive button gets the standard macOS treatment.
            HStack {
                Button("Clear Jira cache") {
                    showClearJiraCacheConfirm = true
                }
                .disabled(jiraCacheClearing)
                if jiraCacheClearing { ProgressView().controlSize(.small) }
                if let status = jiraCacheStatus {
                    Text(status)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Spacer()
            }
        }
        .confirmationDialog(
            "Clear all cached Jira tickets?",
            isPresented: $showClearJiraCacheConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                Task { await clearJiraCache() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Removes every locally cached Jira ticket. Reviews will refetch them on the next run.")
        }
    }

    @ViewBuilder
    private var jiraStatusLabel: some View {
        switch jiraTestStatus {
        case .idle:
            EmptyView()
        case .ok:
            HStack(spacing: 6) {
                Circle().fill(Color.green).frame(width: 8, height: 8)
                Text("Connection OK").foregroundStyle(.secondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 8, height: 8)
                Text(msg).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(.headline)
                Spacer()
                Button("Re-detect all") {
                    toolStatus = BinaryResolver.validate()
                }
            }
            ForEach(Tool.allCases, id: \.self) { tool in
                toolRow(tool)
            }
        }
    }

    private func toolRow(_ tool: Tool) -> some View {
        let status = toolStatus[tool] ?? .missing
        let isFound: Bool = {
            if case .found = status { return true }
            return false
        }()
        let pathString: String = {
            if case .found(let url) = status { return url.path }
            return "not found"
        }()
        return HStack {
            Circle()
                .fill(isFound ? Color.green : Color.red)
                .frame(width: 10, height: 10)
            Text(tool.rawValue)
                .frame(width: 60, alignment: .leading)
                .font(.body.monospaced())
            Text(pathString)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Browse...") { browseFor(tool) }
            if BinaryResolver.readOverride(tool, defaults: .standard) != nil {
                Button("Clear") {
                    BinaryResolver.setOverride(tool, url: nil)
                    toolStatus = BinaryResolver.validate()
                }
            }
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Behavior").font(.headline)
            HStack {
                Text("Concurrency cap")
                Spacer()
                Stepper(value: $concurrencyCap, in: AppSettings.concurrencyCapMin...AppSettings.concurrencyCapMax) {
                    Text("\(concurrencyCap)").frame(width: 30, alignment: .trailing)
                }
                .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Project key prefixes (comma-separated, leave empty to accept any)")
                    .foregroundStyle(.secondary)
                TextField("JWT, ABC, XYZ", text: $prefixesText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    // MARK: - Appearance section (slice 19)

    /// Picker bound directly to `@AppStorage(appearanceKey)` via a two-way
    /// binding on the raw string. This means the live app window
    /// re-evaluates `.preferredColorScheme` immediately without a Save click,
    /// matching macOS system-settings UX conventions.
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Appearance").font(.headline)
            Picker("Color scheme", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("System follows your macOS appearance setting. Light and Dark override it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var wizardSection: some View {
        HStack {
            Spacer()
            Button("Re-run first-run wizard") { showWizardSheet = true }
        }
    }

    // MARK: - Storage section

    /// Slice 17: surfaces disk usage of the local caches (`~/.work-homepage/repos`
    /// and `~/.work-homepage/worktrees`) with a per-repo table and a per-row
    /// "Evict" button. Sizes are I/O-heavy so they're computed off the main
    /// thread, only when the section first appears or when the user clicks
    /// "Refresh sizes" — never on every render. The SwiftData "Reveal in
    /// Finder" affordance from slice 07-fix is preserved at the bottom of the
    /// section.
    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage").font(.headline)
                Spacer()
                Button("Refresh sizes") {
                    Task { await refreshDiskUsage() }
                }
                .disabled(isComputingSizes)
                if isComputingSizes {
                    ProgressView().controlSize(.small)
                }
            }

            // Total disk usage line.
            HStack(alignment: .firstTextBaseline) {
                Text("Cache total")
                    .frame(width: 130, alignment: .leading)
                Text(Self.formatBytes(totalDiskBytes))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Text("(bare clones + worktrees)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                Spacer()
            }

            // Per-repo table.
            perRepoTable

            Divider()

            // SwiftData store reveal (preserved from slice 07-fix).
            HStack(alignment: .firstTextBaseline) {
                Text("SwiftData store")
                    .frame(width: 130, alignment: .leading)
                Text(storeDirectoryURL().path)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Reveal in Finder") {
                    revealStoreInFinder()
                }
            }
        }
        .task {
            // Compute sizes once when the section first appears. Subsequent
            // recomputes happen via the explicit "Refresh sizes" button so we
            // don't pin the disk every time the user opens Settings.
            if perRepoUsage.isEmpty && totalDiskBytes == 0 {
                await refreshDiskUsage()
            }
        }
        .confirmationDialog(
            evictDialogTitle,
            isPresented: Binding(
                get: { pendingEvictRepo != nil },
                set: { if !$0 { pendingEvictRepo = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingEvictRepo
        ) { repo in
            Button("Evict", role: .destructive) {
                evictConfirmed(repo: repo)
            }
            Button("Cancel", role: .cancel) {
                pendingEvictRepo = nil
            }
        } message: { _ in
            Text("This removes the bare clone and all worktrees. Saved reviews and findings persist.")
        }
        .alert(
            "Couldn't evict",
            isPresented: Binding(
                get: { evictError != nil },
                set: { if !$0 { evictError = nil } }
            ),
            presenting: evictError
        ) { _ in
            Button("OK", role: .cancel) { evictError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    @ViewBuilder
    private var perRepoTable: some View {
        if perRepoUsage.isEmpty {
            HStack {
                Text(isComputingSizes ? "Computing sizes…" : "No repo caches on disk yet.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                // Header row.
                HStack(spacing: 8) {
                    Text("Repo")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Bare")
                        .frame(width: 80, alignment: .trailing)
                    Text("Worktree")
                        .frame(width: 80, alignment: .trailing)
                    Text("Total")
                        .frame(width: 80, alignment: .trailing)
                    Text("")
                        .frame(width: 70, alignment: .trailing)
                }
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

                Divider()

                ForEach(perRepoUsage, id: \.repo) { usage in
                    HStack(spacing: 8) {
                        Text(usage.repo)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Text(Self.formatBytes(usage.bareBytes))
                            .font(.callout.monospaced())
                            .frame(width: 80, alignment: .trailing)
                        Text(Self.formatBytes(usage.worktreeBytes))
                            .font(.callout.monospaced())
                            .frame(width: 80, alignment: .trailing)
                        Text(Self.formatBytes(usage.totalBytes))
                            .font(.callout.monospaced())
                            .frame(width: 80, alignment: .trailing)
                        Button("Evict") {
                            pendingEvictRepo = usage.repo
                        }
                        .frame(width: 70, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private var evictDialogTitle: String {
        if let repo = pendingEvictRepo {
            return "Evict all caches for \(repo)?"
        }
        return "Evict all caches?"
    }

    /// `ByteCountFormatter` configured per the slice spec: `.useAll` so we get
    /// KB/MB/GB as appropriate, `.file` for filesystem-style rounding (matches
    /// what Finder shows in column view), and `.allowsNonnumericFormatting` so
    /// "Zero KB" renders for empty caches.
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = .useAll
        f.countStyle = .file
        f.allowsNonnumericFormatting = true
        return f
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }

    /// Recompute disk usage off the main thread. Walking the cache trees is
    /// pure I/O, so we hop to a detached task and then publish the result back
    /// to `@State` on the main actor.
    private func refreshDiskUsage() async {
        if isComputingSizes { return }
        isComputingSizes = true
        defer { isComputingSizes = false }
        let result = await Task.detached(priority: .userInitiated) {
            (
                total: WorktreeManager.diskUsage(),
                perRepo: WorktreeManager.usagePerRepo()
            )
        }.value
        totalDiskBytes = result.total
        perRepoUsage = result.perRepo
    }

    /// Confirmation handler. The `evictAllForRepo` call is `@MainActor`-isolated
    /// because it reads `ReviewOrchestrator.shared` to refuse eviction while a
    /// review is running; the actual `FileManager.removeItem` cost is
    /// dominated by APFS metadata operations which are O(directory entries)
    /// and fast in practice. After eviction succeeds we recompute sizes off
    /// the main thread.
    private func evictConfirmed(repo: String) {
        pendingEvictRepo = nil
        do {
            try WorktreeManager.evictAllForRepo(repo)
            Task { await refreshDiskUsage() }
        } catch let error as WorktreeError {
            if case .cannotEvictWhileReviewRunning(let r) = error {
                evictError = "A review is currently running against \(r). Wait for it to finish before evicting its caches."
            } else {
                evictError = "Eviction failed: \(error)"
            }
        } catch {
            evictError = "Eviction failed: \(error.localizedDescription)"
        }
    }

    /// Resolve the directory containing the SwiftData store. We ask Foundation
    /// for the user's Application Support dir; on a sandboxed build this lands
    /// inside `~/Library/Containers/.../Data/Library/Application Support/`,
    /// on an unsandboxed build it's `~/Library/Application Support/`.
    /// SwiftData drops `default.store` (and its `-wal` / `-shm` siblings) into
    /// that directory by default.
    private func storeDirectoryURL() -> URL {
        let fm = FileManager.default
        if let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return dir
        }
        // Fallback to the modern URL accessor — used on macOS 13+ when the
        // legacy lookup misbehaves.
        return URL.applicationSupportDirectory
    }

    private func revealStoreInFinder() {
        let dir = storeDirectoryURL()
        let storeFile = dir.appending(path: "default.store")
        let fm = FileManager.default
        // Prefer selecting the actual store file when present; otherwise just
        // open the parent directory.
        if fm.fileExists(atPath: storeFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([storeFile])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([dir])
        }
    }

    // MARK: - Actions

    private func loadAll() {
        hasGitHubToken = (KeychainStore.get(key: "github.token") != nil)
        jiraBaseURL = JiraConfig.getBaseURL() ?? ""
        jiraEmail = JiraConfig.getEmail() ?? ""
        jiraToken = JiraConfig.getToken() ?? ""
        toolStatus = BinaryResolver.validate()
        concurrencyCap = AppSettings.concurrencyCap
        prefixesText = AppSettings.projectKeyPrefixes.joined(separator: ", ")
    }

    private func save() {
        JiraConfig.setBaseURL(jiraBaseURL)
        JiraConfig.setEmail(jiraEmail)
        JiraConfig.setToken(jiraToken)
        AppSettings.concurrencyCap = concurrencyCap
        let parts = prefixesText
            .split(whereSeparator: { $0 == "," })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        AppSettings.projectKeyPrefixes = parts
    }

    private func reDetectFromGh() async {
        isReDetectingGitHub = true
        defer { isReDetectingGitHub = false }
        // Force re-probe of `gh` first (clears cache, honours override).
        _ = BinaryResolver.reDetect()
        toolStatus = BinaryResolver.validate()
        if let token = await GitHubTokenBootstrap.bootstrap(), !token.isEmpty {
            KeychainStore.set(key: "github.token", value: token)
            hasGitHubToken = true
        } else {
            hasGitHubToken = (KeychainStore.get(key: "github.token") != nil)
        }
    }

    /// Slice 12 — drop every `CachedJiraTicket` row.
    ///
    /// Implemented by fetching all rows and deleting them one by one
    /// (instead of `context.delete(model:)` which would skip the
    /// `@Attribute(.unique)` cleanup) so the predicate-less `FetchDescriptor`
    /// reflects what the user sees: "wipe the cache". A failure during
    /// delete is surfaced as a status string but doesn't crash the view —
    /// the cache being broken must never block Settings.
    private func clearJiraCache() async {
        if jiraCacheClearing { return }
        jiraCacheClearing = true
        jiraCacheStatus = nil
        defer { jiraCacheClearing = false }
        do {
            let descriptor = FetchDescriptor<CachedJiraTicket>()
            let rows = try modelContext.fetch(descriptor)
            let count = rows.count
            for row in rows {
                modelContext.delete(row)
            }
            try modelContext.save()
            jiraCacheStatus = "Cleared \(count) cached ticket\(count == 1 ? "" : "s")."
        } catch {
            jiraCacheStatus = "Clear failed: \(error.localizedDescription)"
        }
    }

    private func testJira() async {
        jiraTesting = true
        jiraTestStatus = .idle
        defer { jiraTesting = false }
        let result = await JiraConnectionTester.test(
            baseURL: jiraBaseURL,
            email: jiraEmail,
            token: jiraToken
        )
        await MainActor.run {
            switch result {
            case .ok: jiraTestStatus = .ok
            case .failed(let msg): jiraTestStatus = .failed(msg)
            }
        }
    }

    private func browseFor(_ tool: Tool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the \(tool.rawValue) executable"
        panel.prompt = "Use"
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            BinaryResolver.setOverride(tool, url: url)
            toolStatus = BinaryResolver.validate()
        }
    }
}
