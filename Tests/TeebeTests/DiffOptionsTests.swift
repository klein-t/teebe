import Foundation
import SwiftUI
import Testing
@testable import Teebe
import TeebeCore

@MainActor
struct DiffOptionsTests {
    func node(_ name: String) -> FileNode {
        FileNode(path: "/repo/\(name)", isDirectory: false,
                 change: FileChange(path: name, worktreeStatus: .modified))
    }

    func defaults() throws -> UserDefaults {
        let name = "teebe-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func previewAsksGitToIgnoreWhitespaceWhenTheOptionIsOn() async throws {
        let git = FakeGitClient()
        git.workingDiffResult = DiffFile(newPath: "a.swift", hunks: [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1,
            newCount: 1, lines: [DiffLine(kind: .addition, content: "let a = 1")])])
        let defaults = try defaults()
        let model = PreviewModel(environment: makeTestEnvironment(git: git), defaults: defaults)
        await model.toggle(for: node("a.swift"), worktreePath: "/repo")
        #expect(git.workingDiffIgnoreWhitespaceFlags == [false])

        defaults.set(true, forKey: DiffDisplayOptions.ignoreWhitespaceKey)
        await model.reload()
        #expect(git.workingDiffIgnoreWhitespaceFlags == [false, true])
        #expect(model.content == .diff(git.workingDiffResult!))
    }

    @Test func reloadKeepsTheDiffUpWhileAsking() async throws {
        let started = Gate()
        let release = Gate()
        let git = FakeGitClient()
        let first = DiffFile(newPath: "a.swift", hunks: [DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)])
        git.workingDiffResult = first
        let model = PreviewModel(environment: makeTestEnvironment(git: git), defaults: try defaults())
        await model.toggle(for: node("a.swift"), worktreePath: "/repo")
        git.workingDiffHandler = { _ in
            await started.open()
            await release.wait()
            return first
        }
        let task = Task { await model.reload() }
        await started.wait()
        #expect(model.content == .diff(first))
        await release.open()
        await task.value
    }

    @Test func reloadDoesNothingOnceClosed() async throws {
        let git = FakeGitClient()
        git.workingDiffResult = DiffFile(newPath: "a.swift")
        let model = PreviewModel(environment: makeTestEnvironment(git: git), defaults: try defaults())
        await model.toggle(for: node("a.swift"), worktreePath: "/repo")
        model.close()
        await model.reload()
        #expect(git.workingDiffIgnoreWhitespaceFlags.count == 1)
        #expect(model.content == .empty)
    }

    @Test func highlighterStylesKnownLanguagesAndLeavesTheTextIntact() async throws {
        let lines = [DiffLine(kind: .deletion, content: "let total = count // old"),
                     DiffLine(kind: .addition, content: "let total = quantity // new"),
                     DiffLine(kind: .context, content: "")]
        let file = DiffFile(newPath: "a.swift", hunks: [DiffHunk(oldStart: 1, oldCount: 2, newStart: 1, newCount: 2,
                                                                lines: lines)])
        let highlight = try #require(await DiffHighlighter.make(file: file, syntaxColors: true, changedWords: true))
        for (index, line) in lines.enumerated() where !line.content.isEmpty {
            let styled = try #require(highlight.line(0, index))
            #expect(String(styled.characters) == line.content)
        }
        let added = try #require(highlight.line(0, 1))
        #expect(added.runs.contains { $0.backgroundColor != nil })
        #expect(added.runs.contains { $0.foregroundColor != nil })
        #expect(highlight.line(0, 2) == nil)
        #expect(highlight.line(5, 5) == nil)

        // Unknown type with colors only: nothing to do.
        #expect(await DiffHighlighter.make(file: DiffFile(newPath: "a.txt", hunks: file.hunks),
                                           syntaxColors: true, changedWords: false) == nil)
    }

    @Test func shortcutSheetListsTheWhitespaceKey() {
        let items = ShortcutsCatalog.groups.flatMap(\.items)
        #expect(items.contains { $0.keys == "W" && $0.action.contains("ignore whitespace") })
    }
}
