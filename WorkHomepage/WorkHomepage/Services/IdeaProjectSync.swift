//
//  IdeaProjectSync.swift
//  WorkHomepage
//
//  Copies the project-model half of `.idea/` from the user's main checkout
//  into a freshly-prepared worktree, so IntelliJ recognises the worktree as
//  an existing project (with the right SDK, modules, code style, gradle
//  linkage, run configurations) rather than re-importing from Gradle and
//  re-discovering everything.
//
//  We deliberately split `.idea/` into two halves:
//
//   - **Project model** — modules.xml, *.iml, misc.xml, compiler.xml,
//     gradle.xml, vcs.xml, kotlinc.xml, codeStyles/, runConfigurations/,
//     etc. These describe the project itself and use `$PROJECT_DIR$` /
//     `$MODULE_DIR$` macros, so they're path-portable. Copying them is
//     safe and gives the worktree a fully-formed project.
//
//   - **Per-window state** — workspace.xml (open tabs, scroll positions,
//     tool-window layout), tasks.xml, shelf/, httpRequests/, dataSources/,
//     caches/, and other user-state. IntelliJ rewrites these constantly;
//     two windows sharing them race on save (last-writer-wins) and stomp
//     each other's IDE state. We never copy these — the worktree's
//     IntelliJ instance keeps its own.
//
//  Re-sync behaviour: on every `prepare` (including re-reviews) we refresh
//  the project-model files from the user's checkout so module additions /
//  SDK changes / new run configs propagate. Per-window state in the
//  worktree's `.idea/` is left alone.
//

import Foundation

enum IdeaProjectSync {

    /// Per-window / user-state files we never copy. Anything else inside
    /// `.idea/` is treated as project model and propagated.
    ///
    /// Names are matched as the immediate child of `.idea/` (file or
    /// directory). Subtree contents under denied directories aren't
    /// considered.
    static let denylist: Set<String> = [
        // IDE window state — rewritten every few seconds. Sharing these is
        // the documented anti-pattern that B (symlink) would have hit.
        "workspace.xml",
        "tasks.xml",
        "usage.statistics.xml",
        // User-shelved changes: per-user, not project model.
        "shelf",
        // HTTP client scratches: typically per-user request/response cache.
        "httpRequests",
        // DB tooling: connection metadata + cached schemas, sometimes creds.
        "dataSources",
        "dataSources.local.xml",
        "dataSources.ids",
        // JetBrains "Developer Tools" plugin scratchpad — large per-user state.
        "developer-tools.xml",
        // Caches / runtime artifacts.
        "caches",
        ".cache",
        "port",
        "sonarlint",
        // AWS toolkit stores user-tied creds in some setups; safer to skip.
        "aws.xml",
        // Project model snapshots that JetBrains regenerates on indexing.
        "contentModel.xml"
    ]

    /// Copies project-model files from `<sourceRepo>/.idea/` into
    /// `<destRepo>/.idea/`. No-op if the source has no `.idea/`. Existing
    /// allowed files in the destination are overwritten so re-prepare
    /// picks up fresh module / SDK / run-config changes; denied files in
    /// the destination are left untouched so the worktree's IntelliJ
    /// window keeps its own workspace state.
    static func copyProjectModel(from sourceRepo: URL, to destRepo: URL) throws {
        let fm = FileManager.default
        let sourceIdea = sourceRepo.appendingPathComponent(".idea", isDirectory: true)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceIdea.path, isDirectory: &isDir), isDir.boolValue else {
            return
        }
        let destIdea = destRepo.appendingPathComponent(".idea", isDirectory: true)
        try fm.createDirectory(at: destIdea, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(atPath: sourceIdea.path)
        for entry in entries {
            if denylist.contains(entry) { continue }
            let src = sourceIdea.appendingPathComponent(entry)
            let dst = destIdea.appendingPathComponent(entry)
            // Refresh: drop any prior copy at the destination so we always
            // mirror the source's current shape (e.g. a removed module).
            // Only project-model entries hit this branch — workspace.xml
            // et al. are filtered above and stay intact in the dest.
            if fm.fileExists(atPath: dst.path) {
                try fm.removeItem(at: dst)
            }
            try fm.copyItem(at: src, to: dst)
        }

        // Best-effort: rewrite gradle.xml's `gradleJvm` from the env-var
        // macro `#JAVA_HOME` to the project SDK name from misc.xml. The
        // macro fails to resolve in fresh worktrees because the user's
        // explicit Gradle-JVM choice lives in workspace.xml (denylisted),
        // and macOS GUI apps don't inherit a shell-set JAVA_HOME. Pinning
        // to the project SDK matches what the main checkout's IntelliJ
        // window converges on after first sync.
        rewriteGradleJvmToProjectSDK(destIdea: destIdea)
    }

    /// If `<destIdea>/gradle.xml` has a `gradleJvm` option referencing the
    /// `#JAVA_HOME` macro and `<destIdea>/misc.xml` declares a
    /// `project-jdk-name`, rewrites the option to point at that JDK by name.
    /// Silent on any failure — the worst case is the user fixing the Gradle
    /// JVM dropdown once.
    ///
    /// Implementation note: the previous version did a regex/string replace
    /// on the file content. That worked for IntelliJ's canonical layout but
    /// was fragile against attribute reordering, single vs. double quotes,
    /// embedded comments, or any future formatting drift. This version
    /// parses both files with `XMLDocument`, mutates the relevant attribute
    /// node directly, and re-serialises — so any structural shape that
    /// preserves the documented `<option name="gradleJvm" value="..."/>`
    /// element will survive a round-trip cleanly.
    private static func rewriteGradleJvmToProjectSDK(destIdea: URL) {
        let miscURL = destIdea.appendingPathComponent("misc.xml")
        let gradleURL = destIdea.appendingPathComponent("gradle.xml")
        guard
            let miscContent = try? String(contentsOf: miscURL, encoding: .utf8),
            let jdkName = extractProjectJdkName(from: miscContent),
            !jdkName.isEmpty
        else {
            return
        }
        guard
            let gradleData = try? Data(contentsOf: gradleURL),
            let gradleDoc = try? XMLDocument(data: gradleData, options: [.nodePreserveAll])
        else {
            return
        }
        guard rewriteGradleJvmOption(in: gradleDoc, replacement: jdkName) else {
            return
        }
        let serialised = gradleDoc.xmlData(options: [.nodePreserveAll])
        try? serialised.write(to: gradleURL)
    }

    /// Walks every `<option>` element in `doc` and, when it finds one whose
    /// `name` attribute is `gradleJvm` and whose `value` attribute is
    /// `#JAVA_HOME`, replaces that `value` with `replacement`. Returns
    /// `true` iff at least one such option was rewritten.
    ///
    /// IntelliJ's gradle.xml puts the option deeply nested inside
    /// `project › component › option › GradleProjectSettings › option`,
    /// but it could in principle live elsewhere. We don't pin the path —
    /// we match by `(name, value)` and let the structure be whatever the
    /// IDE wrote.
    private static func rewriteGradleJvmOption(in doc: XMLDocument, replacement: String) -> Bool {
        guard let root = doc.rootElement() else { return false }
        var didRewrite = false
        var stack: [XMLElement] = [root]
        while let element = stack.popLast() {
            if element.name == "option",
               let nameAttr = element.attribute(forName: "name")?.stringValue,
               nameAttr == "gradleJvm",
               let valueAttr = element.attribute(forName: "value"),
               valueAttr.stringValue == "#JAVA_HOME" {
                valueAttr.stringValue = replacement
                didRewrite = true
            }
            for child in element.children ?? [] {
                if let childElement = child as? XMLElement {
                    stack.append(childElement)
                }
            }
        }
        return didRewrite
    }

    /// Pulls `project-jdk-name="..."` out of `misc.xml`. Returns `nil` if
    /// the attribute is absent or the document is unparsable.
    ///
    /// Walks the parsed tree looking for a `project-jdk-name` attribute on
    /// any element. IntelliJ canonically puts it on
    /// `<component name="ProjectRootManager">`, but matching by attribute
    /// name keeps us tolerant to minor schema drift.
    static func extractProjectJdkName(from miscXML: String) -> String? {
        guard
            let data = miscXML.data(using: .utf8),
            let doc = try? XMLDocument(data: data, options: [.nodePreserveAll]),
            let root = doc.rootElement()
        else {
            return nil
        }
        var stack: [XMLElement] = [root]
        while let element = stack.popLast() {
            if let value = element.attribute(forName: "project-jdk-name")?.stringValue,
               !value.isEmpty {
                return value
            }
            for child in element.children ?? [] {
                if let childElement = child as? XMLElement {
                    stack.append(childElement)
                }
            }
        }
        return nil
    }
}
