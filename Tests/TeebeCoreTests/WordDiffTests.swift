import Foundation
import Testing
@testable import TeebeCore

@Suite("WordDiff")
struct WordDiffTests {
    func hunk(_ lines: [(DiffLineKind, String)]) -> DiffHunk {
        DiffHunk(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
                 lines: lines.map { DiffLine(kind: $0.0, content: $0.1) })
    }

    func marked(_ text: String, _ spans: [Range<Int>]?) -> [String] {
        let chars = Array(text)
        return (spans ?? []).map { String(chars[$0]) }
    }

    @Test("marks the changed word on both sides of an edited line")
    func singleWord() {
        let old = "let total = price * count"
        let new = "let total = price * quantity"
        let spans = WordDiff.changedSpans(in: hunk([(.deletion, old), (.addition, new)]))
        #expect(marked(old, spans[0]) == ["count"])
        #expect(marked(new, spans[1]) == ["quantity"])
    }

    @Test("neighbouring changed words merge across the space between them")
    func mergesAcrossSpaces() {
        let old = "return a + b"
        let new = "return x * y"
        let spans = WordDiff.changedSpans(in: hunk([(.deletion, old), (.addition, new)]))
        #expect(marked(old, spans[0]) == ["a + b"])
        #expect(marked(new, spans[1]) == ["x * y"])
    }

    @Test("dissimilar lines are not paired")
    func dissimilar() {
        let spans = WordDiff.changedSpans(in: hunk([
            (.deletion, "import Foundation"),
            (.addition, "func render(_ items: [Item]) -> some View {")
        ]))
        #expect(spans.isEmpty)
    }

    @Test("pairs the most similar lines in order, leaving extras unpaired")
    func bestPairing() {
        let old = WordDiff.Words("let width = frame.width")
        let inserted = WordDiff.Words("// A brand new comment line here")
        let edited = WordDiff.Words("let width = frame.width * scale")
        #expect(WordDiff.pairs([old], [inserted, edited]).map { [$0.0, $0.1] } == [[0, 1]])

        let spans = WordDiff.changedSpans(in: hunk([
            (.context, "func layout() {"),
            (.deletion, "    let width = frame.width"),
            (.addition, "    // A brand new comment line here"),
            (.addition, "    let width = frame.width * scale"),
            (.context, "}")
        ]))
        #expect(spans[2] == nil)
        #expect(marked("    let width = frame.width * scale", spans[3]) == [" * scale"])
    }

    @Test("runs separated by context are paired separately")
    func separateRuns() {
        let spans = WordDiff.changedSpans(in: hunk([
            (.deletion, "a = 1"), (.addition, "a = 2"),
            (.context, "b"),
            (.deletion, "c = 3"), (.addition, "c = 4")
        ]))
        #expect(Set(spans.keys) == [0, 1, 3, 4])
    }

    @Test("indentation-only changes mark the leading whitespace")
    func whitespace() {
        let spans = WordDiff.changedSpans(in: hunk([(.deletion, "  value"), (.addition, "    value")]))
        #expect(spans[0] == [0..<2])
        #expect(spans[1] == [0..<4])

        // Ignoring whitespace: only the real edit is marked.
        let edited = WordDiff.changedSpans(in: hunk([(.deletion, "  a = 1"), (.addition, "    a = 2")]),
                                           ignoringWhitespace: true)
        #expect(edited[0] == [6..<7])
        #expect(edited[1] == [8..<9])
    }

    @Test("works on characters: emoji, combining marks, CRLF, tabs")
    func unicode() {
        let old = "label = \"caf\u{65}\u{301} 👩‍👩‍👧\"\r"
        let new = "label = \"caf\u{65}\u{301} 👍🏽\"\r"
        let spans = WordDiff.changedSpans(in: hunk([(.deletion, old), (.addition, new)]))
        #expect(marked(old, spans[0]) == ["👩‍👩‍👧"])
        #expect(marked(new, spans[1]) == ["👍🏽"])
        let tabs = WordDiff.changedSpans(in: hunk([(.deletion, "\tif a {"), (.addition, "\tif b {")]))
        #expect(marked("\tif b {", tabs[1]) == ["b"])
    }

    @Test("overlong, wordy and odd lines are skipped, not stuck")
    func bounded() {
        let long = String(repeating: "x", count: WordDiff.maxLineBytes + 1)
        #expect(WordDiff.changedSpans(in: hunk([(.deletion, long), (.addition, long + "y")])).isEmpty)
        let wordy = Array(repeating: "w", count: WordDiff.maxTokens).joined(separator: " ")
        #expect(WordDiff.changedSpans(in: hunk([(.deletion, wordy), (.addition, wordy + " z")])).isEmpty)
        let odd = ["", "\u{0}\u{1}", "\u{FFFD}\u{FFFD}", " ", "\r"]
        for old in odd { for new in odd { _ = WordDiff.changedSpans(in: hunk([(.deletion, old), (.addition, new)])) } }

        // A big run of near-identical lines falls back to line-by-line pairing.
        let lines = (0..<200).map { "value\($0) = compute(\($0))" }
        let big = hunk(lines.map { (.deletion, $0) } + lines.map { (.addition, $0 + " + 1") })
        let clock = ContinuousClock()
        var spans: [Int: [Range<Int>]] = [:]
        let elapsed = clock.measure { spans = WordDiff.changedSpans(in: big) }
        // Only the added side changed: each added line marks its " + 1".
        #expect(spans.count == 200 && spans.keys.allSatisfy { $0 >= 200 })
        #expect(elapsed < .seconds(2))
    }

    @Test("runs split a line where tokens and changed words meet")
    func runs() {
        let runs = DiffLineRuns.make(length: 10,
                                     tokens: [SyntaxToken(.keyword, 0..<3), SyntaxToken(.string, 6..<10)],
                                     changed: [2..<8])
        #expect(runs == [
            DiffLineRun(0..<2, kind: .keyword),
            DiffLineRun(2..<3, kind: .keyword, changed: true),
            DiffLineRun(3..<6, changed: true),
            DiffLineRun(6..<8, kind: .string, changed: true),
            DiffLineRun(8..<10, kind: .string)
        ])
        #expect(DiffLineRuns.make(length: 0, tokens: [], changed: []).isEmpty)
        #expect(DiffLineRuns.make(length: 3, tokens: [SyntaxToken(.number, 1..<9)], changed: [])
                == [DiffLineRun(0..<1), DiffLineRun(1..<3, kind: .number)])
    }

    @Test("whole-diff styling keeps one entry per line and leaves unknown types plain")
    func wholeDiff() throws {
        let file = DiffFile(newPath: "a.swift", hunks: [hunk([
            (.context, "/* start"), (.deletion, "still comment */ let a = 1"),
            (.addition, "still comment */ let a = 2"), (.context, "")
        ])])
        let runs = try #require(DiffHighlighting.runs(for: file, language: SyntaxLanguage.forPath("a.swift"),
                                                      changedWords: true))
        #expect(runs.count == 1 && runs[0].count == 4)
        #expect(runs[0][1]?.first?.kind == .comment)
        #expect(runs[0][2]?.contains { $0.changed } == true)
        #expect(runs[0][3] == nil)

        let plain = try #require(DiffHighlighting.runs(for: file, language: nil, changedWords: false))
        #expect(plain[0].allSatisfy { $0 == nil })
        #expect(DiffHighlighting.runs(for: file, language: nil, changedWords: true, isCancelled: { true }) == nil)

        let lines = Array(repeating: (DiffLineKind.addition, "let a = 1"), count: DiffHighlighting.maxLines + 1)
        let large = DiffFile(newPath: "a.swift", hunks: [hunk(lines)])
        #expect(DiffHighlighting.runs(for: large, language: SyntaxLanguage.forPath("a.swift"), changedWords: true) == nil)
    }
}
