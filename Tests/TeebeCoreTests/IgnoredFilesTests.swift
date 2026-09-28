import Foundation
import Testing
@testable import TeebeCore

/// What a removal deletes that Git can't restore: every gitignored file, counted
/// inside the folders `git status` collapses, with consent voided by a new one.
@Suite("Ignored files")
struct IgnoredFilesTests {
    @Test("files inside ignored folders are counted one by one, and a huge folder stops at the limit")
    func inventory() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.writeFile("cache/a.bin", "a")
        fixture.writeFile("cache/deep/b.bin", "b")
        fixture.writeFile(".env.local", "TOKEN=1")
        let all = IgnoredFiles.inventory(in: fixture.repoPath, entries: ["cache/", ".env.local"])
        #expect(all.paths == [".env.local", "cache/a.bin", "cache/deep/b.bin"])
        #expect(!all.isTruncated)
        let capped = IgnoredFiles.inventory(in: fixture.repoPath, entries: ["cache/", ".env.local"], limit: 2)
        #expect(capped.paths.count == 2)
        #expect(capped.isTruncated)
        // A folder that went away in between counts as nothing, not as an error.
        #expect(IgnoredFiles.inventory(in: fixture.repoPath, entries: ["gone/"]).paths.isEmpty)
    }

    @Test("names that look hard to get back are picked out; that says nothing about the rest")
    func irreplaceableNames() {
        for path in [".env", ".env.production", "config/app.env", "certs/dev.pem", "tls.key", "store.p12", "cert.pfx",
                     "keys/id_ed25519", "settings.local.json", "config/.local", "app.local"] {
            #expect(IgnoredFiles.looksIrreplaceable(path), "\(path)")
        }
        for path in ["node_modules/react/index.js", ".build/debug/app", "environment.ts", "keyboard.swift", "local/readme.md"] {
            #expect(!IgnoredFiles.looksIrreplaceable(path), "\(path)")
        }
        let files = IgnoredFiles(paths: [".build/x", ".env", "a.pem", "z.txt"], isTruncated: false)
        #expect(files.irreplaceable == [".env", "a.pem"])
    }

    @Test("a file added inside an ignored folder that was already listed voids the confirmation")
    func newFileInListedFolder() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile(".gitignore", "cache/\n")
        let folder = fixture.addWorktree(name: "feature", branch: "feature")
        fixture.commitAndFastForward(branch: "feature", in: folder)
        fixture.writeFile("cache/data.txt", "local", in: folder)
        let service = WorktreeCleanupService(git: ProcessGitClient())
        let reviewed = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "feature" })
        #expect(reviewed.ignoredPaths == ["cache/"])
        #expect(reviewed.ignoredFiles?.paths == ["cache/data.txt"])
        // The folder was listed and still is; what is in it is not what was confirmed.
        fixture.writeFile("cache/secrets.env", "TOKEN=1", in: folder)
        await #expect(throws: CleanupError.changed) {
            try await service.remove(repoPath: fixture.repoPath, entry: reviewed, includingIgnored: true, deleteBranch: false)
        }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("cache/secrets.env").path))
        let again = try #require(try await service.scan(repoPath: fixture.repoPath, extraTarget: nil)
            .entries.first { $0.worktree.branch == "feature" })
        #expect(again.ignoredFiles?.paths == ["cache/data.txt", "cache/secrets.env"])
        try await service.remove(repoPath: fixture.repoPath, entry: again, includingIgnored: true, deleteBranch: false)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
