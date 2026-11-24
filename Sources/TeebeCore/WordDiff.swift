import Foundation

/// Changed words inside edited lines, as GitHub shows them: within a hunk, each
/// run of removed lines is paired with the run of added lines after it, similar
/// lines only, and the differing words of each pair are marked. Pure and bounded.
public enum WordDiff {
    /// Lines longer than this (UTF-8 bytes) are never paired.
    public static let maxLineBytes = 1000
    /// More words than this in a line: no word marks for it.
    public static let maxTokens = 300
    /// Two lines pair only when at least this share of their words is common.
    public static let minSimilarity = 0.5
    /// Larger runs are paired line by line instead of by best match.
    static let maxAlignmentCells = 2500
    /// Larger differing middles are marked whole instead of word by word.
    static let maxLCSCells = 40_000

    /// Changed `Character` ranges per line index of `hunk`. A line without a
    /// similar counterpart has no entry: its whole-line color already says it all.
    /// `ignoringWhitespace` drops spans that are whitespace alone, as git's `-w`.
    public static func changedSpans(in hunk: DiffHunk, ignoringWhitespace: Bool = false) -> [Int: [Range<Int>]] {
        var result: [Int: [Range<Int>]] = [:]
        var removed: [Int] = []
        var added: [Int] = []

        func flush() {
            defer { removed.removeAll(); added.removeAll() }
            guard !removed.isEmpty, !added.isEmpty else { return }
            let old = removed.map { Words(hunk.lines[$0].content) }
            let new = added.map { Words(hunk.lines[$0].content) }
            for (oldIndex, newIndex) in pairs(old, new) {
                guard var spans = spans(old[oldIndex], new[newIndex]) else { continue }
                if ignoringWhitespace {
                    spans.old.removeAll { old[oldIndex].isBlank($0) }
                    spans.new.removeAll { new[newIndex].isBlank($0) }
                }
                if !spans.old.isEmpty { result[removed[oldIndex]] = spans.old }
                if !spans.new.isEmpty { result[added[newIndex]] = spans.new }
            }
        }

        for (index, line) in hunk.lines.enumerated() {
            switch line.kind {
            case .context:
                flush()
            case .deletion:
                if !added.isEmpty { flush() }
                removed.append(index)
            case .addition:
                added.append(index)
            }
        }
        flush()
        return result
    }

    /// Pairs similar lines in order: the best-scoring alignment for normal runs,
    /// line by line for very long ones.
    static func pairs(_ old: [Words], _ new: [Words]) -> [(Int, Int)] {
        if old.count * new.count > maxAlignmentCells {
            return (0..<min(old.count, new.count)).filter { similarity(old[$0], new[$0]) >= minSimilarity }.map { ($0, $0) }
        }
        let rows = old.count, columns = new.count
        var score = Array(repeating: Array(repeating: 0.0, count: columns + 1), count: rows + 1)
        var similar = Array(repeating: Array(repeating: 0.0, count: columns), count: rows)
        for row in 0..<rows {
            for column in 0..<columns { similar[row][column] = similarity(old[row], new[column]) }
        }
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                var best = max(score[row + 1][column], score[row][column + 1])
                if similar[row][column] >= minSimilarity {
                    best = max(best, similar[row][column] + score[row + 1][column + 1])
                }
                score[row][column] = best
            }
        }
        var result: [(Int, Int)] = []
        var row = 0, column = 0
        while row < rows, column < columns {
            let paired = similar[row][column] >= minSimilarity
                && score[row][column] == similar[row][column] + score[row + 1][column + 1]
            if paired {
                result.append((row, column))
                row += 1
                column += 1
            } else if score[row + 1][column] >= score[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return result
    }

    /// The share of non-space text two lines have in common (Dice, by length).
    static func similarity(_ lhs: Words, _ rhs: Words) -> Double {
        guard lhs.isUsable, rhs.isUsable else { return 0 }
        let total = lhs.solidLength + rhs.solidLength
        guard total > 0 else { return lhs.text == rhs.text ? 1 : 0.5 }
        var counts: [String: Int] = [:]
        for word in lhs.words where !word.isSpace { counts[word.text, default: 0] += 1 }
        var common = 0
        for word in rhs.words where !word.isSpace {
            if let count = counts[word.text], count > 0 {
                counts[word.text] = count - 1
                common += word.range.count
            }
        }
        return Double(2 * common) / Double(total)
    }

    /// Changed ranges for a pair of lines; nil when either cannot be compared.
    static func spans(_ old: Words, _ new: Words) -> (old: [Range<Int>], new: [Range<Int>])? {
        guard old.isUsable, new.isUsable else { return nil }
        let lhs = old.words, rhs = new.words
        var prefix = 0
        while prefix < lhs.count, prefix < rhs.count, lhs[prefix].text == rhs[prefix].text { prefix += 1 }
        var suffix = 0
        while suffix < lhs.count - prefix, suffix < rhs.count - prefix,
              lhs[lhs.count - 1 - suffix].text == rhs[rhs.count - 1 - suffix].text { suffix += 1 }
        let oldMiddle = Array(lhs[prefix..<(lhs.count - suffix)])
        let newMiddle = Array(rhs[prefix..<(rhs.count - suffix)])
        var oldChanged = Array(repeating: true, count: oldMiddle.count)
        var newChanged = Array(repeating: true, count: newMiddle.count)
        if oldMiddle.count * newMiddle.count <= maxLCSCells {
            for (oldIndex, newIndex) in commonSubsequence(oldMiddle.map(\.text), newMiddle.map(\.text)) {
                oldChanged[oldIndex] = false
                newChanged[newIndex] = false
            }
        }
        return (merge(oldMiddle, oldChanged), merge(newMiddle, newChanged))
    }

    /// Index pairs of a longest common subsequence.
    static func commonSubsequence(_ lhs: [String], _ rhs: [String]) -> [(Int, Int)] {
        guard !lhs.isEmpty, !rhs.isEmpty else { return [] }
        var length = Array(repeating: Array(repeating: 0, count: rhs.count + 1), count: lhs.count + 1)
        for row in stride(from: lhs.count - 1, through: 0, by: -1) {
            for column in stride(from: rhs.count - 1, through: 0, by: -1) {
                length[row][column] = lhs[row] == rhs[column]
                    ? length[row + 1][column + 1] + 1
                    : max(length[row + 1][column], length[row][column + 1])
            }
        }
        var result: [(Int, Int)] = []
        var row = 0, column = 0
        while row < lhs.count, column < rhs.count {
            if lhs[row] == rhs[column] {
                result.append((row, column))
                row += 1
                column += 1
            } else if length[row + 1][column] >= length[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return result
    }

    /// Adjacent changed words become one span, and so do changed words with only
    /// unchanged spaces between them, so "a b" reads as one change, not two.
    static func merge(_ words: [Word], _ changed: [Bool]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var pendingGap: Range<Int>?
        for (word, isChanged) in zip(words, changed) {
            if isChanged {
                if let last = spans.last, last.upperBound == (pendingGap?.lowerBound ?? word.range.lowerBound) {
                    spans[spans.count - 1] = last.lowerBound..<word.range.upperBound
                } else {
                    spans.append(word.range)
                }
                pendingGap = nil
            } else if word.isSpace, let last = spans.last, last.upperBound == word.range.lowerBound {
                pendingGap = word.range
            } else {
                pendingGap = nil
            }
        }
        return spans
    }

    // MARK: - Words

    struct Word {
        let text: String
        let range: Range<Int>
        let isSpace: Bool
    }

    /// A line split into words (letters, digits, `_`), runs of spaces, and single
    /// other characters, on `Character` boundaries.
    struct Words {
        let text: String
        let words: [Word]
        let isUsable: Bool
        let solidLength: Int

        init(_ text: String) {
            self.text = text
            guard text.utf8.count <= WordDiff.maxLineBytes else {
                words = []
                isUsable = false
                solidLength = 0
                return
            }
            let chars = Array(text)
            var words: [Word] = []
            var index = 0
            while index < chars.count, words.count <= WordDiff.maxTokens {
                let start = index
                let char = chars[index]
                if char.isLetter || char.isNumber || char == "_" {
                    while index < chars.count, chars[index].isLetter || chars[index].isNumber || chars[index] == "_" { index += 1 }
                } else if char.isWhitespace {
                    while index < chars.count, chars[index].isWhitespace { index += 1 }
                } else {
                    index += 1
                }
                words.append(Word(text: String(chars[start..<index]), range: start..<index, isSpace: char.isWhitespace))
            }
            self.words = words
            isUsable = words.count <= WordDiff.maxTokens
            solidLength = words.filter { !$0.isSpace }.reduce(0) { $0 + $1.range.count }
        }

        /// Whether `range` covers only whitespace words.
        func isBlank(_ range: Range<Int>) -> Bool {
            words.allSatisfy { !$0.range.overlaps(range) || $0.isSpace }
        }
    }
}
