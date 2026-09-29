import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
struct RepositorySearchTests {
    @Test func searchesUnopenedFoldersAndRejectsAnOldQuery() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("deep/folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("deep/folder/needle.swift"))
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir.path, repo: Repository(path: dir.path))
        model.searchQuery = "needle"
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.visibleRows.map(\.node.name) == ["needle.swift"])
        #expect(model.expandedPaths.isEmpty)
        model.searchQuery = "needle"
        model.searchQuery = "absent"
        for _ in 0..<100 where model.isSearching { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.visibleRows.isEmpty)
        model.searchQuery = "needle"
        model.clear()
        try await Task.sleep(for: .milliseconds(150))
        #expect(model.visibleRows.isEmpty)
        #expect(!model.isSearching)
    }

    @Test func collapseAvailabilityFollowsVisibleExpandedFolders() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("parent/child"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("parent/child/file.txt"))
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir.path, repo: Repository(path: dir.path))
        #expect(!model.hasExpandedFolders)
        let parent = try #require(model.visibleRows.first?.node)
        model.toggleExpand(parent)
        #expect(model.hasExpandedFolders)
        let child = try #require(model.visibleRows.first { $0.node.name == "child" }?.node)
        model.toggleExpand(child)
        model.toggleExpand(parent)
        #expect(model.expandedPaths.contains(child.path))
        #expect(!model.hasExpandedFolders)
        model.toggleExpand(parent)
        #expect(model.hasExpandedFolders)
        model.searchQuery = "file"
        #expect(!model.hasExpandedFolders)
        model.searchQuery = ""
        #expect(model.hasExpandedFolders)
        model.collapseAll()
        #expect(!model.hasExpandedFolders)
        model.toggleExpand(parent)
        #expect(model.hasExpandedFolders)
        model.clear()
        #expect(!model.hasExpandedFolders)
    }

    @Test func collapseAllRetainsTheVisibleAncestor() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("folder/file.txt"))
        let model = WorktreeModel(environment: makeTestEnvironment())
        await model.load(worktreePath: dir.path, repo: Repository(path: dir.path))
        let folder = try #require(model.visibleRows.first?.node)
        model.toggleExpand(folder)
        model.select(folder.path + "/file.txt")
        model.collapseAll()
        #expect(model.expandedPaths.isEmpty)
        #expect(model.selectedPath == folder.path)
        #expect(model.visibleRows.count == 1)
    }
}
