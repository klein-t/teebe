import Foundation
@testable import TreebranchCore

/// Records open/reveal calls without touching NSWorkspace.
final class FakeFileOpener: FileOpener, @unchecked Sendable {
    private(set) var opened: [URL] = []
    private(set) var openedWith: [(url: URL, app: URL)] = []
    private(set) var revealed: [URL] = []
    var errorToThrow: FileOpenError?

    func open(_ url: URL) throws {
        if let errorToThrow { throw errorToThrow }
        opened.append(url)
    }
    func open(_ url: URL, withApplicationAt appURL: URL) throws {
        openedWith.append((url, appURL))
    }
    func reveal(_ url: URL) { revealed.append(url) }
}

/// Records file-management calls; performs them in-memory-ish on the real temp
/// filesystem only when the test needs side effects (here it just records).
final class FakeFileOps: FileOps, @unchecked Sendable {
    private(set) var renamed: [(url: URL, newName: String)] = []
    private(set) var duplicated: [URL] = []
    private(set) var createdFiles: [(dir: URL, name: String)] = []
    private(set) var createdDirs: [(dir: URL, name: String)] = []
    private(set) var trashed: [URL] = []

    func rename(at url: URL, to newName: String) throws -> URL {
        renamed.append((url, newName))
        return url.deletingLastPathComponent().appendingPathComponent(newName)
    }
    func duplicate(at url: URL) throws -> URL {
        duplicated.append(url)
        return url.deletingLastPathComponent().appendingPathComponent("copy")
    }
    func createFile(in directory: URL, named name: String) throws -> URL {
        createdFiles.append((directory, name))
        return directory.appendingPathComponent(name)
    }
    func createDirectory(in directory: URL, named name: String) throws -> URL {
        createdDirs.append((directory, name))
        return directory.appendingPathComponent(name)
    }
    func moveToTrash(_ url: URL) throws -> URL? {
        trashed.append(url)
        return nil
    }
}
