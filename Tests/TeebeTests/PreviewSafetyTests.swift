import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Teebe
import TeebeCore

@MainActor
struct PreviewSafetyTests {
    func node(_ name: String) -> FileNode {
        FileNode(path: "/repo/\(name)", isDirectory: false,
                 change: FileChange(path: name, worktreeStatus: .modified))
    }

    @Test func closingDuringLoadDoesNotReopen() async {
        let started = Gate()
        let release = Gate()
        let git = FakeGitClient()
        git.workingDiffHandler = { _ in
            await started.open()
            await release.wait()
            return DiffFile(newPath: "slow.swift")
        }
        let model = PreviewModel(environment: makeTestEnvironment(git: git))
        let task = Task { await model.toggle(for: node("slow.swift"), worktreePath: "/repo") }
        await started.wait()
        #expect(model.isVisible)
        model.close()
        await release.open()
        #expect(await task.value == false)
        #expect(!model.isVisible)
        #expect(model.currentPath == nil)
        #expect(model.content == .empty)
    }

    @Test func newestSelectionWins() async {
        let started = Gate()
        let release = Gate()
        let git = FakeGitClient()
        git.workingDiffHandler = { path in
            if path == "slow.swift" {
                await started.open()
                await release.wait()
            }
            return DiffFile(newPath: path)
        }
        let model = PreviewModel(environment: makeTestEnvironment(git: git))
        let task = Task { await model.toggle(for: node("slow.swift"), worktreePath: "/repo") }
        await started.wait()
        await model.update(for: node("new.swift"), worktreePath: "/repo")
        await release.open()
        #expect(await task.value == false)
        #expect(model.currentPath == "/repo/new.swift")
        #expect(model.content == .diff(DiffFile(newPath: "new.swift")))
    }

    @Test func largeDiffHasExplicitFallback() async {
        let git = FakeGitClient()
        git.workingDiffResult = DiffFile(hunks: [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: 1,
            lines: [DiffLine(kind: .addition, content: String(repeating: "x", count: PreviewLimits.lineBytes + 1))])])
        let model = PreviewModel(environment: makeTestEnvironment(git: git))
        await model.toggle(for: node("large.swift"), worktreePath: "/repo")
        #expect(model.content == .tooLarge(URL(fileURLWithPath: "/repo/large.swift")))
    }

    @Test func quickLookIgnoresInvalidIndexes() {
        let host = QuickLookHostView()
        #expect(host.previewPanel(nil, previewItemAt: -1) == nil)
        #expect(host.previewPanel(nil, previewItemAt: 0) == nil)
    }

    @Test func largeTextKeepsWindowSizeBounded() async throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(repeating: "<p>A line of report source text.</p>\n", count: 12138)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let env = makeTestEnvironment()
        let model = PreviewModel(environment: env)
        await model.toggle(for: FileNode(path: url.path, isDirectory: false), worktreePath: "/tmp")
        #expect(model.content == .text(text))
        let host = NSHostingView(rootView: PreviewPanel(preview: model, app: AppModel(environment: env)))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let size = host.fittingSize
        #expect(size.width <= 800)
        #expect(size.height <= 600)
    }

}
