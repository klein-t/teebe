import AppKit
import TeebeCore

/// The app picker behind "Open With": an open panel on /Applications that only
/// accepts applications, like Finder's Open With > Other…
enum AppChooser {
    /// Ask for an app to open files of type `typeKey` (and `file`, when opening
    /// one). Preselects `current`, else the system's default app for `file`.
    /// nil when canceled.
    @MainActor
    static func choose(file: URL?, typeKey: String, current: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = file == nil ? "Choose" : "Open"
        let typeName = FileTypeKey.displayName(forKey: typeKey)
        let kind = typeKey == FileTypeKey.noExtension ? "files with no extension" : "\(typeName) files"
        panel.message = file.map { "Choose an app to open “\($0.lastPathComponent)”. \(Brand.name) will open \(kind) with it from now on." }
            ?? "Choose an app to open \(kind) with."
        // A file URL as the directory opens its folder with the app selected.
        let preselect = current ?? file.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        panel.directoryURL = preselect ?? URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
