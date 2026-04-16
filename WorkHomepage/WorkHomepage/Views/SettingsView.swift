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

    // Pre-Review Summary (slice 25)
    @State private var summaryConcurrencyCap: Int = AppSettings.summaryConcurrencyCapDefault

    // Appearance (slice 19)
    @AppStorage(AppSettings.appearanceKey) private var appearanceRaw: String = Appearance.system.rawValue

    // Review Prompt Template (slice 23)
    @State private var reviewPromptText: String = ReviewPromptStore.defaultTemplate

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

    // Local repos (worktrees inside user-owned clones)
    @State private var localRepoRoots: [URL] = LocalRepoIndex.roots
    @State private var localRepoMapping: [String: URL] = LocalRepoIndex.mapping
    @State private var localRepoOverrides: [String: URL] = LocalRepoIndex.overrides
    @State private var isScanningLocalRepos: Bool = false
    @State private var localRepoScanStatus: String? = nil

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
                reviewPromptSection
                Divider()
                preReviewSummarySection
                Divider()
                localReposSection
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
            Text("GitHub").font(Font.display(size: 14, weight: .bold))
            HStack {
                Circle()
                    .fill(hasGitHubToken ? Color.accentFern : Color.accentTerracotta)
                    .frame(width: 10, height: 10)
                Text(hasGitHubToken ? "Token saved in Keychain" : "No token in Keychain")
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textSecondary)
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
            Text("Jira").font(Font.display(size: 14, weight: .bold))
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
                        .foregroundStyle(Color.textSecondary)
                        .font(Font.appBody(size: 13))
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
                Circle().fill(Color.accentFern).frame(width: 8, height: 8)
                Text("Connection OK").font(Font.appBody(size: 13)).foregroundStyle(Color.textSecondary)
            }
        case .failed(let msg):
            HStack(spacing: 6) {
                Circle().fill(Color.accentTerracotta).frame(width: 8, height: 8)
                Text(msg).font(Font.appBody(size: 13)).foregroundStyle(Color.textSecondary).lineLimit(2)
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tools").font(Font.display(size: 14, weight: .bold))
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
                .fill(isFound ? Color.accentFern : Color.accentTerracotta)
                .frame(width: 10, height: 10)
            Text(tool.rawValue)
                .frame(width: 60, alignment: .leading)
                .font(.body.monospaced())
            Text(pathString)
                .font(.callout.monospaced())
                .foregroundStyle(Color.textSecondary)
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
            Text("Behavior").font(Font.display(size: 14, weight: .bold))
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
                    .font(Font.appBody(size: 12))
                    .foregroundStyle(Color.textMuted)
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
            Text("Appearance").font(Font.display(size: 14, weight: .bold))
            Picker("Color scheme", selection: $appearanceRaw) {
                ForEach(Appearance.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("System follows your macOS appearance setting. Light and Dark override it.")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
        }
    }

    // MARK: - Review Prompt section (slice 23)

    /// Editable PR-body template with live preview and unknown-variable warning.
    private var reviewPromptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Review Prompt").font(Font.display(size: 14, weight: .bold))

            // Editor
            TextEditor(text: $reviewPromptText)
                .font(Font.mono(size: 13))
                .frame(minHeight: 250)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.borderSubtle.opacity(0.4), lineWidth: 1)
                )

            // Variables footer
            Text("Variables: {{repo}}, {{prNumber}}, {{branch}}, {{sha}}")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)

            // Schema directive note
            Text("Schema directive auto-appended if missing.")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)

            // Unknown variable warning
            let unknownVars = PromptInterpolator.unknownVariables(
                in: reviewPromptText,
                knownKeys: ReviewPromptStore.knownVariableKeys
            )
            if !unknownVars.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(unknownVars, id: \.self) { name in
                        Text("Unknown variable: {{\(name)}}")
                            .font(Font.appBody(size: 12))
                            .foregroundStyle(Color.accentMarigold)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentMarigold.opacity(0.15))
                .cornerRadius(6)
            }

            // Reset button
            HStack {
                Button("Reset to default") {
                    ReviewPromptStore().reset()
                    reviewPromptText = ReviewPromptStore.defaultTemplate
                }
                Spacer()
            }

            // Live preview
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(Font.appBody(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                let stubTicket = JiraTicket(
                    key: "JWT-1",
                    summary: "Stub ticket",
                    description: "Stub description for preview.",
                    status: "In Progress",
                    issueType: "Story",
                    priority: "Medium",
                    parentKey: nil
                )
                let previewText = OrchestratorPrompt.build(
                    repo: "Ala-com/foo",
                    prNumber: 123,
                    branch: "feature/JWT-1",
                    sha: "abc1234",
                    jira: stubTicket,
                    template: reviewPromptText
                )
                ScrollView {
                    Text(previewText)
                        .font(Font.mono(size: 11))
                        .foregroundStyle(Color.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 180)
                .background(Color.bgSurface)
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.borderSubtle.opacity(0.4), lineWidth: 1)
                )
            }
        }
        .onAppear {
            reviewPromptText = ReviewPromptStore().current()
        }
        .onChange(of: reviewPromptText) { _, newValue in
            ReviewPromptStore().setCurrent(newValue)
        }
    }

    // MARK: - Pre-Review Summary section (slice 25)

    /// Stepper controlling how many `PreReviewSummaryRunner` invocations may
    /// run concurrently. Independent of the Review concurrency cap.
    private var preReviewSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pre-Review Summary").font(Font.display(size: 14, weight: .bold))
            HStack {
                Text("Concurrent summaries")
                Spacer()
                Stepper(
                    value: $summaryConcurrencyCap,
                    in: AppSettings.summaryConcurrencyCapMin...AppSettings.summaryConcurrencyCapMax
                ) {
                    Text("\(summaryConcurrencyCap)").frame(width: 30, alignment: .trailing)
                }
                .frame(width: 140)
            }
            Text("Maximum simultaneous Claude summary calls. Default \(AppSettings.summaryConcurrencyCapDefault). Independent of the Review concurrency cap.")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)
        }
    }

    private var wizardSection: some View {
        HStack {
            Spacer()
            Button("Re-run first-run wizard") { showWizardSheet = true }
        }
    }

    // MARK: - Local repos section
    //
    // When a `<org>/<repo>` GitHub identifier maps onto a clone the user
    // already owns, `WorktreeManager` creates worktrees inside that clone
    // (`<localRepo>/.worktrees/<pr#>`) instead of inflating a fresh bare clone
    // under `~/.work-homepage/`. The mapping comes from scanning configurable
    // search roots (default `~/src`) and reading each candidate's `origin`
    // remote. The user can also set per-repo overrides by browsing.

    private var localReposSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Local Repos").font(Font.display(size: 14, weight: .bold))
                Spacer()
                Button("Rescan") {
                    Task { await rescanLocalRepos() }
                }
                .disabled(isScanningLocalRepos)
                if isScanningLocalRepos {
                    ProgressView().controlSize(.small)
                }
            }

            Text("Worktrees are created inside any clone listed below at <repo>/.worktrees/<pr#>/. Repos without a local mapping fall back to a bare clone under ~/.work-homepage/.")
                .font(Font.appBody(size: 11))
                .foregroundStyle(Color.textMuted)

            // Search roots
            VStack(alignment: .leading, spacing: 4) {
                Text("Search roots")
                    .font(Font.appBody(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textMuted)
                ForEach(Array(localRepoRoots.enumerated()), id: \.offset) { idx, root in
                    HStack {
                        Text(root.path)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Button("Remove") {
                            localRepoRoots.remove(at: idx)
                            LocalRepoIndex.setRoots(localRepoRoots, defaults: .standard)
                        }
                    }
                }
                HStack {
                    Button("Add root...") {
                        addLocalRepoRoot()
                    }
                    Spacer()
                }
            }

            if let status = localRepoScanStatus {
                Text(status)
                    .font(Font.appBody(size: 12))
                    .foregroundStyle(Color.textSecondary)
            }

            // Repo mapping table
            localReposTable
        }
    }

    @ViewBuilder
    private var localReposTable: some View {
        let combinedKeys: [String] = {
            var seen = Set<String>()
            var out: [String] = []
            for key in localRepoMapping.keys.sorted() where seen.insert(key).inserted {
                out.append(key)
            }
            for key in localRepoOverrides.keys.sorted() where seen.insert(key).inserted {
                out.append(key)
            }
            return out
        }()

        if combinedKeys.isEmpty {
            HStack {
                Text(isScanningLocalRepos ? "Scanning…" : "No local repos found yet. Add a root and Rescan, or set an override.")
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textMuted)
                Spacer()
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Repo")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Path")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("")
                        .frame(width: 160, alignment: .trailing)
                }
                .font(Font.appBody(size: 12, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .padding(.vertical, 4)

                Divider()

                ForEach(combinedKeys, id: \.self) { repo in
                    let path = localRepoOverrides[repo] ?? localRepoMapping[repo]
                    let isOverride = localRepoOverrides[repo] != nil
                    HStack(spacing: 8) {
                        Text(repo)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        HStack(spacing: 4) {
                            Text(path?.path ?? "—")
                                .font(.callout.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            if isOverride {
                                Text("(override)")
                                    .font(Font.appBody(size: 11))
                                    .foregroundStyle(Color.accentMarigold)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 4) {
                            Button("Browse...") {
                                browseForLocalRepo(repo: repo)
                            }
                            if isOverride {
                                Button("Clear") {
                                    LocalRepoIndex.setOverride(repo: repo, url: nil, defaults: .standard)
                                    localRepoOverrides = LocalRepoIndex.overrides
                                }
                            }
                        }
                        .frame(width: 160, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private func addLocalRepoRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick a directory to scan for local repos"
        panel.prompt = "Add"
        if panel.runModal() == .OK, let url = panel.url {
            if !localRepoRoots.contains(where: { $0.path == url.path }) {
                localRepoRoots.append(url)
                LocalRepoIndex.setRoots(localRepoRoots, defaults: .standard)
            }
        }
    }

    private func browseForLocalRepo(repo: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Pick the local clone for \(repo)"
        panel.prompt = "Use"
        if panel.runModal() == .OK, let url = panel.url {
            LocalRepoIndex.setOverride(repo: repo, url: url, defaults: .standard)
            localRepoOverrides = LocalRepoIndex.overrides
        }
    }

    /// Walks the configured roots off the main thread (process spawns are I/O
    /// bound) and writes the result into the persisted mapping.
    private func rescanLocalRepos() async {
        if isScanningLocalRepos { return }
        isScanningLocalRepos = true
        localRepoScanStatus = nil
        defer { isScanningLocalRepos = false }
        let roots = localRepoRoots
        let result = await Task.detached(priority: .userInitiated) { () -> [String: URL] in
            guard let gitURL = BinaryResolver.resolve(.git) else { return [:] }
            return LocalRepoIndex.scan(roots: roots, gitURL: gitURL)
        }.value
        LocalRepoIndex.setMapping(result, defaults: .standard)
        localRepoMapping = result
        localRepoScanStatus = "Found \(result.count) repo\(result.count == 1 ? "" : "s")."
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
                Text("Storage").font(Font.display(size: 14, weight: .bold))
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
                    .foregroundStyle(Color.textMuted)
                    .font(Font.appBody(size: 13))
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
                    .font(Font.mono(size: 12))
                    .foregroundStyle(Color.textMuted)
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
                    .font(Font.appBody(size: 13))
                    .foregroundStyle(Color.textMuted)
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
                .font(Font.appBody(size: 12, weight: .semibold))
                .foregroundStyle(Color.textMuted)
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
        reviewPromptText = ReviewPromptStore().current()
        summaryConcurrencyCap = AppSettings.summaryConcurrencyCap
    }

    private func save() {
        JiraConfig.setBaseURL(jiraBaseURL)
        JiraConfig.setEmail(jiraEmail)
        JiraConfig.setToken(jiraToken)
        AppSettings.concurrencyCap = concurrencyCap
        AppSettings.summaryConcurrencyCap = summaryConcurrencyCap
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
