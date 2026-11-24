import Foundation

/// One stretch of a diff line with a single look: its token class (if any) and
/// whether it is a changed word.
public struct DiffLineRun: Hashable, Sendable {
    public var range: Range<Int>
    public var kind: SyntaxTokenKind?
    public var changed: Bool

    public init(_ range: Range<Int>, kind: SyntaxTokenKind? = nil, changed: Bool = false) {
        self.range = range
        self.kind = kind
        self.changed = changed
    }
}

public enum DiffLineRuns {
    /// Splits `0..<length` where a token or changed span starts or ends. Tokens and
    /// spans are each sorted and non-overlapping; anything out of range is clipped.
    public static func make(length: Int, tokens: [SyntaxToken], changed: [Range<Int>]) -> [DiffLineRun] {
        guard length > 0 else { return [] }
        var cuts: Set<Int> = [0, length]
        for token in tokens { cuts.insert(token.range.lowerBound); cuts.insert(token.range.upperBound) }
        for span in changed { cuts.insert(span.lowerBound); cuts.insert(span.upperBound) }
        let bounds = cuts.filter { $0 >= 0 && $0 <= length }.sorted()
        var runs: [DiffLineRun] = []
        var tokenIndex = 0, spanIndex = 0
        for (start, end) in zip(bounds, bounds.dropFirst()) {
            while tokenIndex < tokens.count, tokens[tokenIndex].range.upperBound <= start { tokenIndex += 1 }
            while spanIndex < changed.count, changed[spanIndex].upperBound <= start { spanIndex += 1 }
            let kind = tokenIndex < tokens.count && tokens[tokenIndex].range.lowerBound <= start ? tokens[tokenIndex].kind : nil
            let isChanged = spanIndex < changed.count && changed[spanIndex].lowerBound <= start
            if let last = runs.last, last.kind == kind, last.changed == isChanged {
                runs[runs.count - 1].range = last.range.lowerBound..<end
            } else {
                runs.append(DiffLineRun(start..<end, kind: kind, changed: isChanged))
            }
        }
        return runs
    }
}

/// Styling for a whole diff, computed off the main thread.
public enum DiffHighlighting {
    /// Above this many lines a diff stays plain: swapping in styled text means
    /// laying every row out again, and that pause would outweigh the colors.
    public static let maxLines = 200

    /// Runs per hunk and line; nil for a line that stays plain. Each side of the
    /// diff carries its own open comment or string from line to line, and every
    /// hunk starts fresh. Returns nil for a diff over `maxLines`, or once
    /// `isCancelled` says so.
    public static func runs(for file: DiffFile, language: SyntaxLanguage?, changedWords: Bool,
                            ignoringWhitespace: Bool = false,
                            isCancelled: () -> Bool = { false }) -> [[[DiffLineRun]?]]? {
        guard file.hunks.reduce(0, { $0 + $1.lines.count }) <= maxLines else { return nil }
        var result: [[[DiffLineRun]?]] = []
        for hunk in file.hunks {
            if isCancelled() { return nil }
            let spans = changedWords ? WordDiff.changedSpans(in: hunk, ignoringWhitespace: ignoringWhitespace) : [:]
            var oldState = SyntaxState.normal
            var newState = SyntaxState.normal
            var lines: [[DiffLineRun]?] = []
            for (index, line) in hunk.lines.enumerated() {
                var tokens: [SyntaxToken] = []
                if let language {
                    switch line.kind {
                    case .deletion:
                        (tokens, oldState) = SyntaxTokenizer.tokenize(line.content, language: language, state: oldState)
                    case .addition:
                        (tokens, newState) = SyntaxTokenizer.tokenize(line.content, language: language, state: newState)
                    case .context:
                        let sameState = oldState == newState
                        (tokens, newState) = SyntaxTokenizer.tokenize(line.content, language: language, state: newState)
                        oldState = sameState ? newState
                            : SyntaxTokenizer.tokenize(line.content, language: language, state: oldState).state
                    }
                }
                let changed = spans[index] ?? []
                if tokens.isEmpty && changed.isEmpty {
                    lines.append(nil)
                } else {
                    lines.append(DiffLineRuns.make(length: line.content.count, tokens: tokens, changed: changed))
                }
            }
            result.append(lines)
        }
        return result
    }
}
