import Foundation
import Testing
@testable import TeebeCore

/// Session text is written by agents and by whatever they read: it must not be
/// able to crash or stall the app, however it is shaped.
@Suite("Agent text bounds")
struct AgentTextBoundsTests {
    @Test("tag blocks are removed in one pass, with look-alikes and joins left as text")
    func removingBlocks() {
        #expect(AgentText.removingBlocks("note", from: "a<note>x</note>b<note id=1>y</note>c") == "abc")
        #expect(AgentText.removingBlocks("note", from: "a<notes>kept</notes><note>gone") == "a<notes>kept</notes>")
        #expect(AgentText.removingBlocks("note", from: "<no<note>x</note>te>stays") == "<note>stays")
        #expect(AgentText.removingBlocks("note", from: "no tags") == "no tags")
    }

    @Test("a prompt full of tag look-alikes cannot overflow the stack, even on a small one")
    func deepLookAlikes() {
        let text = String(repeating: "<notex", count: 200_000)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = ""
        // The transcript scans run on pool threads with half a megabyte of stack.
        let thread = Thread {
            result = AgentText.removingBlocks("note", from: text)
            done.signal()
        }
        thread.stackSize = 512 * 1_024
        thread.start()
        done.wait()
        #expect(result == text)
    }

    @Test("a pile of combining marks cannot hide behind one character")
    func combiningMarks() throws {
        let text = "Approve?" + String(repeating: "\u{0301}", count: 200_000)
        let line = try #require(AgentText.line(text, limit: 70))
        #expect(line.unicodeScalars.count <= 70 * AgentText.scalarsPerCharacter + 1)
        #expect(line.unicodeScalars.starts(with: "Approve?".unicodeScalars) && line.unicodeScalars.last == "…")
        // Ordinary text, marks included, is untouched.
        #expect(AgentText.line("Caff\u{0065}\u{0301} per tutti", limit: 70) == "Caff\u{0065}\u{0301} per tutti")
        #expect(AgentText.line(String(repeating: " ", count: 5_000) + "hello", limit: 70) == "hello")
    }
}
