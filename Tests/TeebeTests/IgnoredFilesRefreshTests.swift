import Foundation
import Testing
import TeebeCore
@testable import Teebe

@MainActor
@Suite("Ignored files after refresh")
struct IgnoredFilesRefreshTests {
    @Test("new ignored files and edited rules are reflected without switching worktrees")
    func refreshesIgnoreRules() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = ProcessGitClient()
        try await git.run(["init", "-q"], in: directory.path)
        try Data("*.log\n".utf8).write(to: directory.appendingPathComponent(".gitignore"))
        try Data().write(to: directory.appendingPathComponent("old.log"))
        let environment = AppEnvironment(git: git, opener: FakeFileOpener(), ops: FakeFileOps(),
            store: AppStateStore(url: directory.appendingPathComponent("state.json")),
            activityMonitor: WorktreeActivityMonitor(), makeWatcher: { FakeWatcher() })
        let model = WorktreeModel(environment: environment)
        await model.load(worktreePath: directory.path, repo: Repository(path: directory.path))
        #expect(!model.visibleRows.contains { $0.node.name == "old.log" })
        try Data().write(to: directory.appendingPathComponent("new.log"))
        await model.refresh()
        #expect(!model.visibleRows.contains { $0.node.name == "new.log" })
        model.showIgnored = true
        #expect(model.visibleRows.contains { $0.node.name == "new.log" })
        model.showIgnored = false
        #expect(!model.visibleRows.contains { $0.node.name == "new.log" })
        try Data().write(to: directory.appendingPathComponent(".gitignore"))
        await model.refresh()
        #expect(model.visibleRows.contains { $0.node.name == "old.log" })
        #expect(model.visibleRows.contains { $0.node.name == "new.log" })
    }
}
