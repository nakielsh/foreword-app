//
//  SettingsView.swift
//  WorkHomepage
//
//  App-wide settings exposed via the macOS Settings menu (`Cmd-,`).
//  Mirrors the first-run wizard but always available, and adds re-detect /
//  re-paste-token controls.
//

import SwiftUI
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

    // Sheets
    @State private var showRePasteTokenSheet: Bool = false
    @State private var showWizardSheet: Bool = false

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

    private var wizardSection: some View {
        HStack {
            Spacer()
            Button("Re-run first-run wizard") { showWizardSheet = true }
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
