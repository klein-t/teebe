import SwiftUI
import TeebeCore

extension ChangeStatus {
    /// Plain-language explanation shared by the Files and Changes badges.
    var helpText: String {
        switch self {
        case .unmodified: return "Unmodified file · No changes"
        case .modified: return "Modified file · Changed since the last commit"
        case .added: return "Added file · Added to Git for the next commit"
        case .deleted: return "Deleted file · Removed from this checkout"
        case .renamed: return "Renamed file · Moved or renamed"
        case .copied: return "Copied file · Copied from another tracked file"
        case .conflicted: return "Conflicted file · Resolve the merge conflict"
        case .untracked: return "Untracked file · Not yet added to Git"
        case .ignored: return "Ignored file · Excluded by Git ignore rules"
        case .typeChanged: return "File type changed · For example, a file became a symbolic link"
        }
    }
}

/// SF Symbol for a file, by extension — shared by the FILES tree and the CHANGES
/// rows so the same file gets the same icon in both lists.
enum FileIcon {
    static func symbol(forFileNamed name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "pdf": return "photo"
        default: return "doc"
        }
    }
}

extension FileNode {
    /// SF Symbol name for the file-row icon.
    var iconName: String {
        isDirectory ? "folder" : FileIcon.symbol(forFileNamed: name)
    }
}

extension FileChange {
    /// SF Symbol name for the change-row icon.
    var iconName: String {
        FileIcon.symbol(forFileNamed: (path as NSString).lastPathComponent)
    }
}
