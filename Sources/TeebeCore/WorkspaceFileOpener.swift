import Foundation
import AppKit

public enum FileOpenError: Error, Equatable, Sendable {
    case openFailed(URL)
}

/// `FileOpener` backed by `NSWorkspace` (D1): files open in their native app, in
/// their own window.
public struct WorkspaceFileOpener: FileOpener {
    public init() {}

    public func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else { throw FileOpenError.openFailed(url) }
    }

    public func open(_ url: URL, withApplicationAt appURL: URL) throws {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration)
    }

    public func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
