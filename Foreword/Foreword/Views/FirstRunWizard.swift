//
//  FirstRunWizard.swift
//  Foreword
//
//  Single-sheet, scrollable, skippable-per-section first-run setup.
//  Sections: GitHub token, Jira config, Tool paths (plus the bundled review
//  skill), Project key prefixes, Concurrency cap. Each section has its own "Skip" affordance — pressing
//  Done writes whatever the user did fill in.
//
//  Re-openable from SettingsView via "Re-run first-run wizard".
//

import SwiftUI
import AppKit

struct FirstRunWizard: View {

    static let firstRunCompletedKey = "firstRun.completed"

    let onFinished: () -> Void

    // GitHub
    @State private var ghToken: String = ""
    @State private var ghBootstrapStatus: BootstrapStatus = .unknown
    @State private var ghBootstrapping: Bool = false
    @State private var skipGitHub: Bool = false

    // Jira
    @State private var jiraBaseURL: String = ""
    @State private var jiraEmail: String = ""
    @State private var jiraToken: String = ""
    @State private var jiraTestStatus: JiraTestStatus = .idle
    @State private var jiraTesting: Bool = false
    @State private var skipJira: Bool = false

    // Tools
    @State private var toolStatus: [Tool: ResolverStatus] = [:]
    @State private var skipTools: Bool = false

    // Prefixes
    @State private var prefixesText: String = ""
    @State private var skipPrefixes: Bool = false

    // Concurrency
    @State private var concurrencyCap: Int = AppSettings.concurrencyCapDefault
    @State private var skipConcurrency: Bool = false

    @Environment(\.dismiss) private var dismiss

    enum BootstrapStatus: Equatable {
        case unknown
        case foundFromGh
        case missingGh
    }

    enum JiraTestStatus: Equatable {
        case idle
        case ok
        case failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                Divider()
                gitHubSection
                Divider()
                jiraSection
                Divider()
                toolsSection
                Divider()
                prefixesSection
                Divider()
                concurrencySection
                Divider()
                footer
            }
            .padding(20)
            .frame(width: 560)
        }
        .frame(width: 560, height: 700)
        .onAppear { loadInitial() }
        .task {
            // Probe binaries off the main thread.
            await reprobeBinaries()
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome").font(Font.display(size: 24, weight: .bold))
            Text("Walk through the one-time setup. Each section is skippable; you can come back from Settings.")
                .font(Font.appBody(size: 13))
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var gitHubSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("1. GitHub token", skipBinding: $skipGitHub)
            if !skipGitHub {
                // Consent copy — explain what "Try gh auth token" actually
                // does before the user clicks. Replaces the silent
                // `gh auth token` invocation that used to run during app
                // launch without user awareness.
                Text("Foreword can read your existing `gh` CLI token and store it in your macOS Keychain. The token never leaves your machine — it is used only to call the GitHub REST and GraphQL APIs from within this app. You can also paste a token manually below, or skip this step entirely.")
                    .font(Font.appBody(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch ghBootstrapStatus {
                case .unknown:
                    HStack {
                        Button("Try gh auth token") {
                            Task { await tryBootstrap() }
                        }
                        .disabled(ghBootstrapping)
                        if ghBootstrapping { ProgressView().controlSize(.small) }
                    }
                case .foundFromGh:
                    HStack(spacing: 6) {
                        Circle().fill(Color.accentFern).frame(width: 8, height: 8)
                        Text("Token loaded from gh and saved to Keychain.")
                            .font(Font.appBody(size: 13))
                            .foregroundStyle(Color.textSecondary)
                    }
                case .missingGh:
                    Text("Could not auto-fetch. Paste a token below.")
                        .font(Font.appBody(size: 13))
                        .foregroundStyle(Color.textMuted)
                }
                SecureField("ghp_… or github_pat_…", text: $ghToken)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var jiraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("2. Jira config", skipBinding: $skipJira)
            if !skipJira {
                TextField("Base URL", text: $jiraBaseURL).textFieldStyle(.roundedBorder)
                TextField("Email", text: $jiraEmail).textFieldStyle(.roundedBorder)
                SecureField("API token", text: $jiraToken).textFieldStyle(.roundedBorder)
                HStack {
                    Button("Test connection") {
                        Task { await testJira() }
                    }
                    .disabled(jiraTesting || jiraBaseURL.isEmpty || jiraEmail.isEmpty || jiraToken.isEmpty)
                    if jiraTesting { ProgressView().controlSize(.small) }
                    jiraStatusLabel
                }
            }
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
                Text("OK").font(Font.appBody(size: 13)).foregroundStyle(Color.textSecondary)
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
            sectionHeader("3. Tool paths", skipBinding: $skipTools)
            if !skipTools {
                HStack {
                    Spacer()
                    Button("Re-detect") {
                        Task { await reprobeBinaries() }
                    }
                }
                ForEach(Tool.allCases, id: \.self) { tool in
                    toolRow(tool)
                }
                ReviewSkillRow()
            }
        }
    }

    /// Probe binaries off the main thread — `BinaryResolver.validate()` spawns
    /// a `Process` per tool which would otherwise freeze the wizard sheet
    /// while it waits on `waitUntilExit`.
    @MainActor
    private func reprobeBinaries() async {
        let probed = await Task.detached(priority: .userInitiated) {
            BinaryResolver.validate()
        }.value
        toolStatus = probed
    }

    private func toolRow(_ tool: Tool) -> some View {
        let status = toolStatus[tool] ?? .missing
        let ok: Bool = {
            if case .found = status { return true }
            return false
        }()
        let pathString: String = {
            if case .found(let url) = status { return url.path }
            return "not found"
        }()
        return HStack {
            Circle().fill(ok ? Color.accentFern : Color.accentTerracotta).frame(width: 10, height: 10)
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
        }
    }

    private var prefixesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("4. Project key prefixes", skipBinding: $skipPrefixes)
            if !skipPrefixes {
                Text("Comma-separated. `feature/KEY-123` branches always work; listing your keys also finds them in branches like `KEY-123-fix` or `jane/KEY-123`.")
                    .font(Font.appBody(size: 12))
                    .foregroundStyle(Color.textMuted)
                TextField("PROJ, ABC", text: $prefixesText)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var concurrencySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("5. Concurrency cap", skipBinding: $skipConcurrency)
            if !skipConcurrency {
                HStack {
                    Text("Reviews running in parallel")
                    Spacer()
                    Stepper(value: $concurrencyCap, in: AppSettings.concurrencyCapMin...AppSettings.concurrencyCapMax) {
                        Text("\(concurrencyCap)").frame(width: 30, alignment: .trailing)
                    }
                    .frame(width: 140)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func sectionHeader(_ title: String, skipBinding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(Font.display(size: 14, weight: .bold))
            Spacer()
            Toggle("Skip", isOn: skipBinding).toggleStyle(.checkbox)
        }
    }

    // MARK: - Actions

    private func loadInitial() {
        if KeychainStore.get(key: "github.token") != nil {
            ghBootstrapStatus = .foundFromGh
        }
        jiraBaseURL = JiraConfig.getBaseURL() ?? ""
        jiraEmail = JiraConfig.getEmail() ?? ""
        jiraToken = JiraConfig.getToken() ?? ""
        // toolStatus is loaded async via `.task` on the body; leave at empty
        // so the wizard sheet doesn't block on subprocess probes during the
        // initial render.
        prefixesText = AppSettings.projectKeyPrefixes.joined(separator: ", ")
        concurrencyCap = AppSettings.concurrencyCap
    }

    private func tryBootstrap() async {
        ghBootstrapping = true
        defer { ghBootstrapping = false }
        if let token = await GitHubTokenBootstrap.bootstrap(), !token.isEmpty {
            KeychainStore.set(key: "github.token", value: token)
            ghBootstrapStatus = .foundFromGh
        } else {
            ghBootstrapStatus = .missingGh
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
            Task { await reprobeBinaries() }
        }
    }

    private func finish() {
        // GitHub
        if !skipGitHub {
            let trimmed = ghToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                KeychainStore.set(key: "github.token", value: trimmed)
            }
        }
        // Jira
        if !skipJira {
            JiraConfig.setBaseURL(jiraBaseURL)
            JiraConfig.setEmail(jiraEmail)
            JiraConfig.setToken(jiraToken)
        }
        // Tools — overrides + cache already persisted as the user clicked.
        // Prefixes
        if !skipPrefixes {
            let parts = prefixesText
                .split(whereSeparator: { $0 == "," })
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            AppSettings.projectKeyPrefixes = parts
        }
        // Concurrency
        if !skipConcurrency {
            AppSettings.concurrencyCap = concurrencyCap
        }

        UserDefaults.standard.set(true, forKey: Self.firstRunCompletedKey)
        onFinished()
        dismiss()
    }
}
