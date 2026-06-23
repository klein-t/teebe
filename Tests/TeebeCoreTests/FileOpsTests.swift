import Testing
import Foundation
@testable import TeebeCore

@Suite("FileManagerFileOps")
struct FileOpsTests {
    private func makeDir() throws -> (URL, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tb-ops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, { try? FileManager.default.removeItem(at: dir) })
    }

    let ops = FileManagerFileOps()

    @Test("rename moves the file")
    func rename() throws {
        let (dir, cleanup) = try makeDir(); defer { cleanup() }
        let file = dir.appendingPathComponent("old.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let result = try ops.rename(at: file, to: "new.txt")
        #expect(result.lastPathComponent == "new.txt")
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
    }

    @Test("duplicate creates a non-clobbering copy")
    func duplicate() throws {
        let (dir, cleanup) = try makeDir(); defer { cleanup() }
        let file = dir.appendingPathComponent("doc.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        let first = try ops.duplicate(at: file)
        #expect(first.lastPathComponent == "doc copy.txt")
        #expect(FileManager.default.fileExists(atPath: first.path))

        let second = try ops.duplicate(at: file)
        #expect(second.lastPathComponent == "doc copy 2.txt")
    }

    @Test("createFile and createDirectory")
    func create() throws {
        let (dir, cleanup) = try makeDir(); defer { cleanup() }
        let file = try ops.createFile(in: dir, named: "fresh.txt")
        #expect(FileManager.default.fileExists(atPath: file.path))

        let sub = try ops.createDirectory(in: dir, named: "subdir")
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: sub.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
    }

    @Test("createFile throws when the file already exists")
    func createExisting() throws {
        let (dir, cleanup) = try makeDir(); defer { cleanup() }
        _ = try ops.createFile(in: dir, named: "dupe.txt")
        #expect(throws: FileOperationError.self) {
            _ = try ops.createFile(in: dir, named: "dupe.txt")
        }
    }

    @Test("moveToTrash removes the original (recoverable, not rm)")
    func trash() throws {
        let (dir, cleanup) = try makeDir(); defer { cleanup() }
        let file = dir.appendingPathComponent("trashme.txt")
        try "bye".write(to: file, atomically: true, encoding: .utf8)

        let trashURL = try ops.moveToTrash(file)
        #expect(FileManager.default.fileExists(atPath: file.path) == false)
        // Clean up the trashed item if the OS reported its new location.
        if let trashURL { try? FileManager.default.removeItem(at: trashURL) }
    }
}

@Suite("FileOpener / FileOps fakes")
struct FileOpenerFakeTests {
    @Test("FakeFileOpener records open and reveal")
    func opener() throws {
        let opener = FakeFileOpener()
        let url = URL(fileURLWithPath: "/x/y.txt")
        try opener.open(url)
        opener.reveal(url)
        #expect(opener.opened == [url])
        #expect(opener.revealed == [url])
    }

    @Test("FakeFileOps records trash")
    func ops() throws {
        let ops = FakeFileOps()
        let url = URL(fileURLWithPath: "/x/y.txt")
        _ = try ops.moveToTrash(url)
        #expect(ops.trashed == [url])
    }
}
