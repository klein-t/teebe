import Foundation
import Testing
import TeebeCore

struct RepositorySearchCoreTests {
    @Test func ignoredRegularFilesDoNotSkipSiblingFolders() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        var ignored: Set<String> = []
        for index in 0..<20 {
            let parent = "folder-\(index)"
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(parent), withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(parent + "/ignored.txt"))
            ignored.insert(parent + "/ignored.txt")
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(parent + "/nested"), withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(parent + "/nested/needle.txt"))
        }
        let builder = FileTreeBuilder(rootPath: dir.path, options: .init(ignoredPaths: ignored))
        #expect(try builder.search("needle").count == 20)
    }

    @Test func excludesIgnoredMetadataAndDirectorySymlinks() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for folder in ["src/deep", "ignored", ".git"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(folder + "/needle.txt"))
        }
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("loop"), withDestinationURL: dir)
        let hidden = FileTreeBuilder(rootPath: dir.path, options: .init(ignoredPaths: ["ignored/"]))
        #expect(try hidden.search("needle").map(\.path) == [PathUtil.standardized(dir.path) + "/src/deep/needle.txt"])
        let shown = FileTreeBuilder(rootPath: dir.path, options: .init(showIgnored: true))
        #expect(try shown.search("needle").count == 2)
    }
}
