import Foundation

/// One row in the Keyboard Shortcuts cheat sheet: the key combo and what it does.
struct ShortcutItem: Identifiable {
    let keys: String
    let action: String
    var id: String { keys + "\u{1}" + action }
}

/// A titled group of related shortcuts (a section of the cheat sheet).
struct ShortcutGroup: Identifiable {
    let title: String
    let items: [ShortcutItem]
    var id: String { title }
}

/// The single source of truth for the cheat sheet. Mirror this whenever a shortcut
/// changes in `RootView`/`FilesSection` so the sheet stays accurate.
enum ShortcutsCatalog {
    static let groups: [ShortcutGroup] = [
        ShortcutGroup(title: "Sections", items: [
            ShortcutItem(keys: "⌘1 / ⌘2 / ⌘3", action: "Focus Worktrees / Changes / Files (again to collapse)"),
            ShortcutItem(keys: "Tab / ⇧Tab", action: "Cycle the active section")
        ]),
        ShortcutGroup(title: "Navigate", items: [
            ShortcutItem(keys: "↑ / ↓", action: "Move selection in the active section"),
            ShortcutItem(keys: "→", action: "Expand folder / go to first child"),
            ShortcutItem(keys: "←", action: "Collapse folder / go to parent"),
            ShortcutItem(keys: "Return", action: "Open file · switch worktree · open change"),
            ShortcutItem(keys: "Space", action: "Quick Look a file / peek a change's diff")
        ]),
        ShortcutGroup(title: "Select files", items: [
            ShortcutItem(keys: "⇧↑ / ⇧↓", action: "Extend the selection"),
            ShortcutItem(keys: "⌘A", action: "Select all files"),
            ShortcutItem(keys: "⌘-click", action: "Add or remove one file"),
            ShortcutItem(keys: "⇧-click", action: "Select a range")
        ]),
        ShortcutGroup(title: "Files actions", items: [
            ShortcutItem(keys: "⌘F", action: "Jump to search"),
            ShortcutItem(keys: "⌘⇧C", action: "Copy selection as @-refs"),
            ShortcutItem(keys: "⌘⌫", action: "Move selection to Trash")
        ]),
        ShortcutGroup(title: "Search", items: [
            ShortcutItem(keys: "↓", action: "Drop from the search box into results"),
            ShortcutItem(keys: "Esc", action: "Clear the query, then return to the tree")
        ])
    ]
}
