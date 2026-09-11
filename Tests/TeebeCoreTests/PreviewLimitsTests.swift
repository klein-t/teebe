import Foundation
import Testing
@testable import TeebeCore

struct PreviewLimitsTests {
    @Test func boundedTextLoading() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("hello 😀\n".utf8).write(to: url)
        #expect(PreviewTextLoader.load(url) == .text("hello 😀\n"))
        try Data().write(to: url)
        #expect(PreviewTextLoader.load(url) == .text(""))
        try Data(repeating: 65, count: PreviewLimits.textBytes).write(to: url)
        if case .text = PreviewTextLoader.load(url) {} else { Issue.record("boundary should load") }
        try Data(repeating: 65, count: PreviewLimits.textBytes + 1).write(to: url)
        #expect(PreviewTextLoader.load(url) == .tooLarge)
        try Data([0xFF, 0xFE]).write(to: url)
        #expect(PreviewTextLoader.load(url) == .unreadable)
        try FileManager.default.removeItem(at: url)
        #expect(PreviewTextLoader.load(url) == .unreadable)
        #expect(PreviewTextLoader.load(FileManager.default.temporaryDirectory) == .unreadable)
    }

    @Test func diffLimitsIncludeLongLinesAndHeaders() {
        func diff(_ text: String, count: Int = 1, header: String = "") -> DiffFile {
            DiffFile(hunks: [DiffHunk(oldStart: 1, oldCount: 0, newStart: 1, newCount: count,
                header: header, lines: Array(repeating: DiffLine(kind: .addition, content: text), count: count))])
        }
        #expect(PreviewLimits.canRender(diff("ordinary source")))
        #expect(PreviewLimits.canRender(diff("x", count: PreviewLimits.diffLines - 1)))
        #expect(!PreviewLimits.canRender(diff("x", count: PreviewLimits.diffLines)))
        #expect(!PreviewLimits.canRender(diff(String(repeating: "x", count: PreviewLimits.lineBytes + 1))))
        #expect(!PreviewLimits.canRender(diff("", header: String(repeating: "x", count: PreviewLimits.lineBytes + 1))))
        #expect(!PreviewLimits.canRender(diff(String(repeating: "x", count: 1024), count: 257)))
    }
}
