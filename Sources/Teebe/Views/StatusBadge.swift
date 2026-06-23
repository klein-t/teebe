import SwiftUI
import TeebeCore

extension FileNode {
    /// SF Symbol name for the file-row icon.
    var iconName: String {
        if isDirectory { return "folder" }
        switch (name as NSString).pathExtension.lowercased() {
        case "swift": return "swift"
        case "md", "markdown", "txt": return "doc.text"
        case "json", "yml", "yaml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "pdf": return "photo"
        default: return "doc"
        }
    }
}
