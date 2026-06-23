import Foundation

/// File-management operations (rename/duplicate/new/trash). Deletes go to the
/// Trash, never `rm` (D3). `FileManagerFileOps` is the production implementation.
public protocol FileOps: Sendable {
    /// Rename the item at `url`, returning its new URL.
    @discardableResult
    func rename(at url: URL, to newName: String) throws -> URL

    /// Duplicate the item at `url` (e.g. `name copy.ext`), returning the new URL.
    @discardableResult
    func duplicate(at url: URL) throws -> URL

    /// Create an empty file named `name` inside `directory`, returning its URL.
    @discardableResult
    func createFile(in directory: URL, named name: String) throws -> URL

    /// Create a directory named `name` inside `directory`, returning its URL.
    @discardableResult
    func createDirectory(in directory: URL, named name: String) throws -> URL

    /// Move the item at `url` to the Trash (recoverable). Returns the resulting
    /// trash URL if the platform provides one.
    @discardableResult
    func moveToTrash(_ url: URL) throws -> URL?
}
