import SwiftUI
import TeebeCore

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
