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

/// The Settings window (⌘,). Worktree preferences share their wording and state
/// with the shortcuts in the worktrees menu.
struct SettingsView: View {
    @Bindable var app: AppModel
    @ObservedObject var updater: UpdaterController
    /// The repository whose extra merge branch is being picked.
    @State private var branchPickerRepo: Repository?

    var body: some View {
        Form {
            Picker("Appearance", selection: $app.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Section("Worktrees") {
                explainedToggle(WorktreePreferences.groupingTitle, isOn: $app.groupWorktreesByMergeStatus,
                                explanation: WorktreePreferences.groupingHelp)
                explainedToggle(WorktreePreferences.fetchTitle, isOn: $app.fetchAutomatically,
                                explanation: WorktreePreferences.fetchHelp)
                extraMergeTargetRow
            }

            openWithSection

            Section {
                Toggle("Automatically check for updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.setAutomaticallyChecksForUpdates($0) }
                ))
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("Updates")
            } footer: {
                Text("When off, teebe checks only when you choose Check for Updates.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $branchPickerRepo) { repo in
            ComparisonBranchSheet(branches: app.mergeStatus.snapshot?.targets.branches ?? [],
                                  saved: app.extraMergeTarget(for: repo.path) ?? "") { ref in
                app.setExtraMergeTarget(ref.isEmpty ? nil : ref, for: repo.path)
            }
        }
    }

    /// The one extra branch the selected repository's worktrees are also checked
    /// against, beyond the automatic ones.
    private var extraMergeTargetRow: some View {
        let repo = app.selector.selectedRepo
        // The saved choice is not observable itself; its revision is.
        _ = app.mergeTargetRevision
        let saved = repo.flatMap { app.extraMergeTarget(for: $0.path) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(WorktreePreferences.extraTargetTitle)
                HelpInfo(title: WorktreePreferences.extraTargetTitle, explanation: WorktreePreferences.extraTargetHelp)
                Spacer(minLength: 4)
                Button("Choose…") { branchPickerRepo = repo }
            }
            HStack(spacing: 4) {
                (Text(repo.map { "\($0.name): " } ?? "").foregroundColor(.secondary)
                    + Text(saved.map(Self.displayName) ?? "None").foregroundColor(saved == nil ? .secondary : .primary))
                    .lineLimit(1).truncationMode(.middle)
                if saved != nil, let repo {
                    Button {
                        app.setExtraMergeTarget(nil, for: repo.path)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the extra branch")
                    .hoverHelp("Clear the extra branch")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
        }
        .disabled(repo == nil)
    }

    /// The app remembered for each file type: change it, or forget it so the next
    /// open asks again.
    private var openWithSection: some View {
        Section {
            if app.openWith.entries.isEmpty {
                Text("None yet. The first time you open a file type, \(Brand.name) asks which app to use.")
                    .font(Typography.secondary).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(app.openWith.entries) { entry in
                    openWithRow(entry)
                }
            }
        } header: {
            HStack {
                Text("Open files with")
                Spacer()
                if !app.openWith.entries.isEmpty {
                    Button("Forget All") { app.openWith.forgetAll() }
                        .buttonStyle(.link).font(Typography.secondary)
                }
            }
        }
    }

    private func openWithRow(_ entry: OpenWithModel.Entry) -> some View {
        HStack(spacing: 6) {
            Text(entry.typeName)
                .font(entry.typeKey == FileTypeKey.noExtension ? Typography.body : .system(size: 12, design: .monospaced))
                .foregroundStyle(entry.typeKey == FileTypeKey.noExtension ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Image(nsImage: NSWorkspace.shared.icon(forFile: entry.appURL.path))
                .resizable().frame(width: 16, height: 16)
            Text(entry.appName)
                .lineLimit(1).truncationMode(.tail)
            Button("Change…") { app.openWith.changeApp(forType: entry.typeKey) }
                .controlSize(.small)
            Button {
                app.openWith.forget(type: entry.typeKey)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forget the app for \(entry.typeName)")
            .hoverHelp("Forget, so the next open asks again")
        }
    }

    /// `refs/remotes/origin/release/2` reads as `origin/release/2`.
    private static func displayName(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }

    private func explainedToggle(_ title: String, isOn: Binding<Bool>, explanation: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            HelpInfo(title: title, explanation: explanation)
            Spacer(minLength: 4)
            Toggle(title, isOn: isOn).labelsHidden()
        }
    }
}
