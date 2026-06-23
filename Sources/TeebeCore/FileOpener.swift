import Foundation

/// Opens files in their native apps and reveals them in Finder. Wraps
/// `NSWorkspace` in production (`WorkspaceFileOpener`); faked in tests.
public protocol FileOpener: Sendable {
    /// Open `url` in its default native application (own window).
    func open(_ url: URL) throws

    /// Open `url` with a specific application bundle (`Open With…`).
    func open(_ url: URL, withApplicationAt appURL: URL) throws

    /// Reveal `url` in Finder.
    func reveal(_ url: URL)
}
