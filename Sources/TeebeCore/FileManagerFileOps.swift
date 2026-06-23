import Foundation

public enum FileOperationError: Error, Equatable, Sendable {
    case alreadyExists(URL)
    case creationFailed(URL)
}

/// `FileOps` implemented with `FileManager`. Deletes go to the Trash (D3), never
/// `rm`.
public struct FileManagerFileOps: FileOps {
    private var fm: FileManager { FileManager.default }
    public init() {}

    @discardableResult
    public func rename(at url: URL, to newName: String) throws -> URL {
        let destination = url.deletingLastPathComponent().appendingPathComponent(newName)
        guard !fm.fileExists(atPath: destination.path) else { throw FileOperationError.alreadyExists(destination) }
        try fm.moveItem(at: url, to: destination)
        return destination
    }

    @discardableResult
    public func duplicate(at url: URL) throws -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent

        func candidate(_ suffix: String) -> URL {
            let name = ext.isEmpty ? "\(base)\(suffix)" : "\(base)\(suffix).\(ext)"
            return directory.appendingPathComponent(name)
        }

        var target = candidate(" copy")
        var counter = 2
        while fm.fileExists(atPath: target.path) {
            target = candidate(" copy \(counter)")
            counter += 1
        }
        try fm.copyItem(at: url, to: target)
        return target
    }

    @discardableResult
    public func createFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard !fm.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists(url) }
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw FileOperationError.creationFailed(url)
        }
        return url
    }

    @discardableResult
    public func createDirectory(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: url.path) else { throw FileOperationError.alreadyExists(url) }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}
