import Foundation

/// File-tree filter (PRD §5.1: `All | Changed`).
public enum ChangeFilter: String, Sendable, CaseIterable, Equatable {
    case all
    case changed
}

/// File-tree sort order (PRD §5.1: `Sort: name | recently changed`).
public enum FileSortOrder: String, Sendable, CaseIterable, Equatable {
    case name
    case recent
}

/// What the spacebar Quick Look panel should show for a selection (D1, PRD §5.2).
public enum PreviewKind: Equatable, Sendable {
    /// Tracked change → unified diff.
    case diff
    /// Text file (md/code/txt) or untracked new file → read-only content preview.
    case text
    /// Anything else → hand off to the system Quick Look.
    case quickLook
}

/// Decides how to preview a selected file. Pure and table-testable.
public enum PreviewResolver {
    /// Extensions teebe renders as in-app text (otherwise system Quick Look).
    public static let textExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst",
        "swift", "h", "m", "mm", "c", "cc", "cpp", "hpp",
        "js", "jsx", "ts", "tsx", "json", "yml", "yaml", "toml", "xml", "html", "css", "scss",
        "py", "rb", "go", "rs", "java", "kt", "kts", "php", "pl", "sh", "bash", "zsh", "fish",
        "swiftpm", "gitignore", "gitattributes", "cfg", "ini", "conf", "env", "lock",
        "sql", "graphql", "proto", "gradle", "make", "mk", "cmake", "dockerfile",
        "log", "csv", "tsv", "plist", "entitlements", "resolved",
    ]

    public static func isTextFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext.isEmpty {
            // Dotfiles / extension-less config commonly are text.
            let lower = name.lowercased()
            return lower.hasPrefix(".") || lower == "makefile" || lower == "dockerfile" || lower == "license" || lower == "readme"
        }
        return textExtensions.contains(ext)
    }

    /// Resolve the preview kind for a file: a tracked change diffs; an untracked or
    /// unchanged text file previews its content; anything else hands off to Quick Look.
    public static func kind(forFileName name: String, change: FileChange?) -> PreviewKind {
        if let change, !change.isUntracked {
            return .diff
        }
        if isTextFile(name) {
            return .text
        }
        return .quickLook
    }
}
