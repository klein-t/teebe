import AppKit
import TeebeCore

/// The app picker behind "Open With": an open panel on /Applications that only
/// accepts applications, like Finder's Open With > Other…
enum AppChooser {
    /// Ask for an app to open files of type `typeKey` (and `file`, when opening
    /// one). Suggests `current`, else the system's default app for `file`: the panel
    /// starts in its folder and names it. nil when canceled.
    @MainActor
    static func choose(file: URL?, typeKey: String, current: URL?) -> URL? {
        let panel = panel(file: file, typeKey: typeKey, current: current)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @MainActor
    static func panel(file: URL?, typeKey: String, current: URL?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.application]
        panel.prompt = file == nil ? "Choose" : "Open"
        let typeName = FileTypeKey.displayName(forKey: typeKey)
        let kind = typeKey == FileTypeKey.noExtension ? "files with no extension" : "\(typeName) files"
        let suggested = current ?? file.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        let suggestion = suggested.map { " \(current == nil ? "The default is" : "Now") \(FileManager.default.displayName(atPath: $0.path))." } ?? ""
        panel.message = (file.map { "Choose an app to open “\($0.lastPathComponent)”. \(Brand.name) will open \(kind) with it from now on." }
            ?? "Choose an app to open \(kind) with.") + suggestion
        // Start in the suggested app's folder. (Pointing the panel at the app itself
        // browses into its package instead of selecting it.)
        panel.directoryURL = suggested?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/Applications")
        return panel
    }
}
