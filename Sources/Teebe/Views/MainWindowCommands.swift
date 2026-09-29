import SwiftUI

/// Actions belong to the focused main window, so Settings and preview windows
/// cannot accidentally operate on a file selection in the background.
struct MainWindowActions {
    var focusSection: (AppModel.FocusSection) -> Void
    var search: () -> Void
    var collapseFolders: () -> Void
    var copyReferences: () -> Void
    var copyPaths: () -> Void
    var trash: () -> Void
    var hasFileSelection: Bool
    var hasExpandedFolders: Bool
}

private struct MainWindowActionsKey: FocusedValueKey {
    typealias Value = MainWindowActions
}

extension FocusedValues {
    var mainWindowActions: MainWindowActions? {
        get { self[MainWindowActionsKey.self] }
        set { self[MainWindowActionsKey.self] = newValue }
    }
}

struct MainWindowCommands: Commands {
    @FocusedValue(\.mainWindowActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Divider()
            Button("Copy File References") { actions?.copyReferences() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(actions?.hasFileSelection != true)
            Button("Copy Full Path") { actions?.copyPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(actions?.hasFileSelection != true)
            Button("Move to Trash") { actions?.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.hasFileSelection != true)
        }
        CommandGroup(after: .sidebar) {
            Button("Focus Worktrees") { actions?.focusSection(.worktrees) }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(actions == nil)
            Button("Focus Changes") { actions?.focusSection(.changes) }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(actions == nil)
            Button("Focus Files") { actions?.focusSection(.files) }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(actions == nil)
            Divider()
            Button("Search Files…") { actions?.search() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(actions == nil)
            Button("Collapse All Folders") { actions?.collapseFolders() }
                .disabled(actions?.hasExpandedFolders != true)
        }
    }
}
