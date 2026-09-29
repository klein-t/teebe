import SwiftUI
import AppKit
import TeebeCore

/// The user's appearance choice. `system` follows macOS; the others force it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Push the choice to every window (and future ones) at once. `NSApp` is nil
    /// under `swift test` (no application object), so this is a no-op there.
    @MainActor func apply() {
        guard let app = NSApp else { return }
        switch self {
        case .system: app.appearance = nil
        case .light: app.appearance = NSAppearance(named: .aqua)
        case .dark: app.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Standard macOS Settings (Command-comma) edits defaults, never the currently
/// selected project's overrides. The main-window menus own those overrides.
struct SettingsView: View {
    @Bindable var app: AppModel
    @ObservedObject var updater: UpdaterController
    @State private var newType = ""
    @State private var comparison = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            worktrees.tabItem { Label("Worktrees", systemImage: "arrow.triangle.branch") }
            files.tabItem { Label("Files", systemImage: "doc") }
            integrations.tabItem { Label("Integrations", systemImage: "link") }
            updates.tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .padding(12)
        .frame(width: 480, height: 480)
        .onAppear {
            comparison = app.preferences.defaults.comparisonRef ?? ""
        }
    }

    private var scope: some View {
        Text("Settings sets defaults. Changes in a project override them.")
            .font(Typography.secondary).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var general: some View {
        Form {
            Section("General") {
                Picker("Appearance", selection: $app.appearance) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
                Toggle("Keep window on top", isOn: $app.floatOnTop)
            }
            Section {
                Toggle("Also delete the local branch when removing a worktree", isOn: $app.deleteBranchOnRemove)
            } header: { Text("Cleanup") } footer: {
                Text("Starts off. The removal dialog remembers your last choice and checks before deleting.")
            }
        }.formStyle(.grouped)
    }

    private var worktrees: some View {
        Form {
            Section {
                scope
                Toggle(WorktreePreferences.groupingTitle, isOn: boolean(\.groupByStatus, fallback: false))
                Picker("Sort", selection: string(\.worktreeSort, fallback: "folder")) {
                    ForEach(WorktreeSortOrder.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle(WorktreePreferences.fetchTitle, isOn: boolean(\.fetchAutomatically, fallback: true))
                Text(WorktreePreferences.fetchHelp).font(Typography.secondary).foregroundStyle(.secondary)
            } header: { Text("Defaults for all projects") }
            Section("Comparison and location") {
                HStack {
                    TextField("Extra comparison branch", text: $comparison, prompt: Text("e.g. release"))
                        .onSubmit { app.preferences.defaults.comparisonRef = comparison }
                    Button("Apply") { app.preferences.defaults.comparisonRef = comparison }
                        .disabled(comparison == (app.preferences.defaults.comparisonRef ?? ""))
                }
                Text("Checked in projects where this branch exists. Choose a project override from its Worktrees menu.")
                    .font(Typography.secondary).foregroundStyle(.secondary)
                HStack {
                    Text("New worktree folder")
                    Spacer()
                    Button("Choose…") { app.chooseWorktreeParentDefault() }
                }
                HStack {
                    Text(app.preferences.defaults.worktreeParent ?? "Automatic, beside the project")
                        .font(Typography.secondary).foregroundStyle(.secondary).lineLimit(2)
                    if app.preferences.defaults.worktreeParent != nil {
                        Button("Reset") { app.preferences.defaults.worktreeParent = nil }
                    }
                }
            }
        }.formStyle(.grouped)
    }

    private var files: some View {
        Form {
            Section("Defaults for all projects") {
                scope
                Toggle("Changed only", isOn: boolean(\.changedOnly, fallback: false))
                Toggle("Show ignored", isOn: boolean(\.showIgnored, fallback: false))
                Picker("Sort", selection: string(\.fileSort, fallback: "name")) {
                    Text("Name").tag("name")
                    Text("Recently changed").tag("recent")
                }
            }
            Section("Open files with") {
                Picker("Default", selection: Binding(get: { app.openWith.policy }, set: { app.openWith.policy = $0 })) {
                    Text("macOS default apps").tag(OpenWithModel.Policy.system)
                    Text("One app").tag(OpenWithModel.Policy.application)
                    Text("Ask for each new type").tag(OpenWithModel.Policy.ask)
                }
                if app.openWith.policy == .application {
                    HStack {
                        Text(app.openWith.defaultApp.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Choose an app")
                        Spacer()
                        Button("Choose…") { app.openWith.chooseDefaultApp() }
                    }
                }
                ForEach(app.openWith.entries) { entry in
                    HStack {
                        Text(entry.typeName).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(entry.appName).lineLimit(1)
                        Button("Change…") { app.openWith.changeApp(forType: entry.typeKey) }
                        Button {
                            app.openWith.forget(type: entry.typeKey)
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(IconButtonStyle(size: CGSize(width: 24, height: 24)))
                        .accessibilityLabel("Use default app for \(entry.typeName)")
                    }
                }
                HStack {
                    TextField("File type, e.g. .md", text: $newType)
                    Button("Add…") { app.openWith.addType(newType); newType = "" }
                        .disabled(newType.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Type overrides win. Open With in a project remembers a choice for that project only.")
                    .font(Typography.secondary).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var integrations: some View {
        Form {
            Section("Terminal") {
                Picker("Open worktrees in", selection: $app.terminal) {
                    ForEach(TerminalChoice.allCases) { Text($0.title).tag($0) }
                }
                if app.terminal == .cmux {
                    Text("Opens a workspace in cmux. Keep cmux running.").font(Typography.secondary).foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }

    private var updates: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }))
                Button("Check for Updates…") { updater.checkForUpdates() }.disabled(!updater.canCheckForUpdates)
            } header: { Text("Updates") } footer: {
                Text("When off, teebe checks only when you choose Check for Updates.")
            }
        }.formStyle(.grouped)
    }

    private func boolean(_ key: WritableKeyPath<ProjectPreferences, Bool?>, fallback: Bool) -> Binding<Bool> {
        Binding(get: { app.preferences.defaults[keyPath: key] ?? fallback },
                set: { app.preferences.defaults[keyPath: key] = $0 })
    }
    private func string(_ key: WritableKeyPath<ProjectPreferences, String?>, fallback: String) -> Binding<String> {
        Binding(get: { app.preferences.defaults[keyPath: key] ?? fallback },
                set: { app.preferences.defaults[keyPath: key] = $0 })
    }
}
