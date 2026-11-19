import Foundation

/// The few token classes the diff preview colors.
public enum SyntaxTokenKind: String, Hashable, Sendable {
    case comment, string, number, keyword, type
}

/// A colored span of one line, in `Character` offsets, so a span can never
/// start or end inside a grapheme (emoji, combining marks, CRLF).
public struct SyntaxToken: Hashable, Sendable {
    public var kind: SyntaxTokenKind
    public var range: Range<Int>

    public init(_ kind: SyntaxTokenKind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

/// What a construct left open at the end of a line (a block comment, a
/// multi-line string, a Markdown code fence, an HTML tag), carried to the next
/// line of the same side of a diff.
public enum SyntaxState: Hashable, Sendable {
    case normal
    case blockComment(Int)
    case string(Int)
    case fence
    case tag
}

/// A deliberately small, line-based tokenizer: enough to tell comments, strings,
/// numbers, keywords and types apart in a diff, never a parser. Pure and bounded.
public enum SyntaxTokenizer {
    /// Lines longer than this (UTF-8 bytes) stay plain.
    public static let maxLineBytes = 2000

    public static func tokenize(_ line: String, language: SyntaxLanguage,
                                state: SyntaxState = .normal) -> (tokens: [SyntaxToken], state: SyntaxState) {
        guard line.utf8.count <= maxLineBytes, !looksBinary(line) else { return ([], state) }
        var scanner = Scanner(chars: Array(line), language: language, state: state)
        scanner.run()
        return (scanner.tokens, scanner.state)
    }

    /// NUL or other C0 controls besides tab, CR and form feed: not source text.
    static func looksBinary(_ line: String) -> Bool {
        line.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" && $0 != "\r" && $0 != "\u{0C}" }
    }
}

// MARK: - Scanner

private struct Scanner {
    let chars: [Character]
    let language: SyntaxLanguage
    var state: SyntaxState
    var tokens: [SyntaxToken] = []
    var index = 0

    init(chars: [Character], language: SyntaxLanguage, state: SyntaxState) {
        self.chars = chars
        self.language = language
        self.state = state
    }

    mutating func run() {
        switch language.family {
        case .markdown: markdownLine()
        case .markup: markupLine()
        default: codeLine()
        }
    }

    // MARK: Shared helpers

    func matches(_ text: [Character], at position: Int) -> Bool {
        guard position + text.count <= chars.count, !text.isEmpty else { return false }
        for offset in 0..<text.count where chars[position + offset] != text[offset] { return false }
        return true
    }

    func find(_ text: [Character], from position: Int) -> Int? {
        var cursor = position
        while cursor + text.count <= chars.count {
            if matches(text, at: cursor) { return cursor }
            cursor += 1
        }
        return nil
    }

    mutating func emit(_ kind: SyntaxTokenKind, _ start: Int, _ end: Int) {
        guard end > start else { return }
        if let last = tokens.last, last.kind == kind, last.range.upperBound == start {
            tokens[tokens.count - 1].range = last.range.lowerBound..<end
        } else {
            tokens.append(SyntaxToken(kind, start..<end))
        }
    }

    func isIdentifierStart(_ char: Character) -> Bool {
        char.isLetter || char == "_" || language.identifierExtras.contains(char)
    }

    func isIdentifierPart(_ char: Character) -> Bool {
        char.isLetter || char.isNumber || char == "_" || language.identifierExtras.contains(char)
    }

    static func isDigit(_ char: Character) -> Bool { char.isASCII && char.isNumber }

    func nextNonSpace(from position: Int) -> Int {
        var cursor = position
        while cursor < chars.count, chars[cursor] == " " || chars[cursor] == "\t" { cursor += 1 }
        return cursor
    }

    /// Ends the string that opened with `quote`, or nil when the line ends first.
    func closing(of quote: SyntaxLanguage.Quote, from position: Int) -> Int? {
        var cursor = position
        while cursor < chars.count {
            if quote.escapes, chars[cursor] == "\\" { cursor += 2; continue }
            if matches(quote.close, at: cursor) { return cursor + quote.close.count }
            cursor += 1
        }
        return nil
    }

    // MARK: Code

    mutating func codeLine() {
        if resumeOpenConstruct() { return }
        if language.family == .keyValue { keyPrefix() }
        while index < chars.count {
            if scanCommentOrString() { if state != .normal { return }; continue }
            let char = chars[index]
            if Self.isDigit(char), index == 0 || !isIdentifierPart(chars[index - 1]) {
                scanNumber()
            } else if isIdentifierStart(char) {
                scanIdentifier()
            } else if !scanPrefixed(char) {
                index += 1
            }
        }
    }

    /// Continues a block comment or multi-line string from the previous line.
    /// True when the whole line is consumed.
    mutating func resumeOpenConstruct() -> Bool {
        switch state {
        case .blockComment(let which):
            let close = language.blockComments[which].close
            if let end = find(close, from: 0) {
                emit(.comment, 0, end + close.count)
                index = end + close.count
                state = .normal
                return false
            }
            emit(.comment, 0, chars.count)
            return true
        case .string(let which):
            let quote = language.quotes[which]
            if let end = closing(of: quote, from: 0) {
                emit(.string, 0, end)
                index = end
                state = .normal
                return false
            }
            emit(.string, 0, chars.count)
            return true
        default:
            state = .normal
            return false
        }
    }

    /// Comments and strings at `index`. True when something was consumed.
    mutating func scanCommentOrString() -> Bool {
        for (which, block) in language.blockComments.enumerated() where matches(block.open, at: index) {
            if let end = find(block.close, from: index + block.open.count) {
                emit(.comment, index, end + block.close.count)
                index = end + block.close.count
            } else {
                emit(.comment, index, chars.count)
                index = chars.count
                state = .blockComment(which)
            }
            return true
        }
        for marker in language.lineComments where matches(marker, at: index) {
            if language.commentNeedsSpaceBefore, index > 0, chars[index - 1] != " ", chars[index - 1] != "\t" { continue }
            emit(.comment, index, chars.count)
            index = chars.count
            return true
        }
        for (which, quote) in language.quotes.enumerated() where matches(quote.open, at: index) {
            let bodyStart = index + quote.open.count
            if let end = closing(of: quote, from: bodyStart) {
                // Rust: 'a' and '\n' are characters, 'a in <'a> is a lifetime.
                if quote.shortLiteral, end - bodyStart - quote.close.count != 1,
                   chars[bodyStart] != "\\" || end - index > 12 { continue }
                markString(from: index, to: end)
                index = end
            } else if quote.shortLiteral {
                continue
            } else {
                emit(.string, index, chars.count)
                index = chars.count
                if quote.multiline { state = .string(which) }
            }
            return true
        }
        return false
    }

    /// A JSON key (a string followed by a colon) reads as a type, like a YAML key.
    mutating func markString(from start: Int, to end: Int) {
        if language.family == .json, chars.indices.contains(nextNonSpace(from: end)),
           chars[nextNonSpace(from: end)] == ":" {
            emit(.type, start, end)
        } else {
            emit(.string, start, end)
        }
    }

    mutating func scanNumber() {
        let start = index
        let isHex = chars[index] == "0" && index + 1 < chars.count && (chars[index + 1] == "x" || chars[index + 1] == "X")
        index += 1
        while index < chars.count {
            let char = chars[index]
            if char.isASCII && (char.isLetter || char.isNumber) || char == "_" {
                index += 1
            } else if char == ".", index + 1 < chars.count, Self.isDigit(chars[index + 1]) {
                index += 1
            } else if char == "+" || char == "-", !isHex, chars[index - 1] == "e" || chars[index - 1] == "E" {
                index += 1
            } else {
                break
            }
        }
        emit(.number, start, index)
    }

    mutating func scanIdentifier() {
        let start = index
        index += 1
        while index < chars.count, isIdentifierPart(chars[index]) { index += 1 }
        let word = String(chars[start..<index])
        if let kind = classify(word, start: start) { emit(kind, start, index) }
    }

    func classify(_ word: String, start: Int) -> SyntaxTokenKind? {
        let key = language.caseInsensitive ? word.lowercased() : word
        if language.keywords.contains(key) { return .keyword }
        if language.types.contains(key) { return .type }
        if language.jsxTags, start > 0, chars[start - 1] == "<" || (chars[start - 1] == "/" && start > 1 && chars[start - 2] == "<") {
            return .type
        }
        if language.family == .css, chars.indices.contains(nextNonSpace(from: index)),
           chars[nextNonSpace(from: index)] == ":", !chars.contains("{") {
            return .type
        }
        if language.capitalizedTypes, let first = word.first, first.isUppercase,
           word.contains(where: { $0.isLowercase }) {
            return .type
        }
        return nil
    }

    /// `@attribute`, `#directive`, `$variable`, `!important`, CSS `#hex`.
    mutating func scanPrefixed(_ char: Character) -> Bool {
        guard index + 1 < chars.count,
              isIdentifierStart(chars[index + 1]) || Self.isDigit(chars[index + 1]) || char == "$" && chars[index + 1] == "{" else {
            return false
        }
        guard let kind = prefixKind(char) else { return false }
        let start = index
        index += 1
        if chars[index] == "{" {
            if let end = chars[index...].firstIndex(of: "}") { index = end + 1 } else { index = chars.count }
        } else {
            while index < chars.count, isIdentifierPart(chars[index]) || char == "@" && chars[index] == "." { index += 1 }
        }
        emit(kind, start, index)
        return true
    }

    func prefixKind(_ char: Character) -> SyntaxTokenKind? {
        switch char {
        case "@": return language.atWords
        case "#" where language.hashDirectives && chars[0..<index].allSatisfy({ $0 == " " || $0 == "\t" }): return .keyword
        case "#" where language.family == .css: return isHexColor(after: index) ? .number : nil
        case "$": return language.dollarVariables ? .type : nil
        case "!" where language.family == .css: return .keyword
        default: return nil
        }
    }

    func isHexColor(after hash: Int) -> Bool {
        var end = hash + 1
        while end < chars.count, isIdentifierPart(chars[end]) { end += 1 }
        let digits = chars[(hash + 1)..<end]
        return [3, 4, 6, 8].contains(digits.count) && digits.allSatisfy(\.isHexDigit)
    }

    /// YAML `key:` and TOML `key =` / `[table]` at the start of a line.
    mutating func keyPrefix() {
        var cursor = nextNonSpace(from: 0)
        if cursor + 1 < chars.count, chars[cursor] == "-", chars[cursor + 1] == " " {
            emit(.keyword, cursor, cursor + 1)
            cursor = nextNonSpace(from: cursor + 1)
        }
        guard cursor < chars.count else { return }
        if chars[cursor] == "[", language.name == "TOML" {
            let end = (chars[cursor...].lastIndex(of: "]") ?? chars.count - 1) + 1
            emit(.keyword, cursor, end)
            index = end
            return
        }
        guard chars[cursor] != "#", chars[cursor] != "\"", chars[cursor] != "'" else { return }
        let separator: Character = language.name == "TOML" ? "=" : ":"
        var end = cursor
        while end < chars.count, chars[end] != separator, chars[end] != "#" { end += 1 }
        guard end < chars.count, chars[end] == separator else { return }
        if separator == ":", end + 1 < chars.count, chars[end + 1] != " ", chars[end + 1] != "\t" { return }
        var keyEnd = end
        while keyEnd > cursor, chars[keyEnd - 1] == " " || chars[keyEnd - 1] == "\t" { keyEnd -= 1 }
        emit(.type, cursor, keyEnd)
        index = end
    }

    // MARK: Markdown

    mutating func markdownLine() {
        let lead = nextNonSpace(from: 0)
        let fence = matches(Array("```"), at: lead) || matches(Array("~~~"), at: lead)
        if state == .fence {
            emit(.string, 0, chars.count)
            if fence { state = .normal }
            return
        }
        if case .blockComment = state {
            if !resumeOpenConstruct() { markdownInline() }
            return
        }
        if fence, lead <= 3 {
            emit(.string, 0, chars.count)
            state = .fence
            return
        }
        guard lead < chars.count, !markdownWholeLine(lead) else { return }
        index = lead
        if listMarkerEnd(at: lead) > lead {
            emit(.keyword, lead, listMarkerEnd(at: lead))
            index = listMarkerEnd(at: lead)
        }
        markdownInline()
    }

    /// A heading or a quote colors the whole line.
    mutating func markdownWholeLine(_ lead: Int) -> Bool {
        if chars[lead] == ">" {
            emit(.comment, lead, chars.count)
            return true
        }
        guard chars[lead] == "#" else { return false }
        var hashes = lead
        while hashes < chars.count, chars[hashes] == "#" { hashes += 1 }
        guard hashes - lead <= 6, hashes == chars.count || chars[hashes] == " " else { return false }
        emit(.keyword, lead, chars.count)
        return true
    }

    func listMarkerEnd(at position: Int) -> Int {
        guard position < chars.count else { return position }
        if "-*+".contains(chars[position]), position + 1 < chars.count, chars[position + 1] == " " {
            return position + 1
        }
        var cursor = position
        while cursor < chars.count, Self.isDigit(chars[cursor]) { cursor += 1 }
        if cursor > position, cursor + 1 < chars.count, chars[cursor] == "." || chars[cursor] == ")", chars[cursor + 1] == " " {
            return cursor + 1
        }
        return position
    }

    mutating func markdownInline() {
        while index < chars.count {
            if scanCommentOrString() { if state != .normal { return }; continue }
            if chars[index] == "`" {
                var ticks = index
                while ticks < chars.count, chars[ticks] == "`" { ticks += 1 }
                let marker = Array(chars[index..<ticks])
                if let end = find(marker, from: ticks) {
                    emit(.string, index, end + marker.count)
                    index = end + marker.count
                } else {
                    index = ticks
                }
            } else if chars[index] == "]", index + 1 < chars.count, chars[index + 1] == "(",
                      let close = chars[(index + 1)...].firstIndex(of: ")") {
                emit(.type, index + 1, close + 1)
                index = close + 1
            } else {
                index += 1
            }
        }
    }

    // MARK: HTML / XML

    mutating func markupLine() {
        if case .blockComment = state {
            if resumeOpenConstruct() { return }
        }
        var inTag = state == .tag
        state = .normal
        while index < chars.count {
            if inTag {
                inTag = scanInsideTag()
            } else if scanCommentOrString() {
                if state != .normal { return }
            } else {
                inTag = scanOutsideTag()
            }
        }
        if inTag { state = .tag }
    }

    /// Text between tags: a tag opening (true from then on) or an entity.
    mutating func scanOutsideTag() -> Bool {
        if chars[index] == "<", index + 1 < chars.count,
           chars[index + 1] == "/" || chars[index + 1] == "!" || chars[index + 1] == "?" || chars[index + 1].isLetter {
            index += chars[index + 1].isLetter ? 1 : 2
            let start = index
            while index < chars.count, isIdentifierPart(chars[index]) || chars[index] == ":" { index += 1 }
            emit(.keyword, start, index)
            return true
        }
        if chars[index] == "&", let end = chars[index...].prefix(12).firstIndex(of: ";") {
            emit(.number, index, end + 1)
            index = end + 1
        } else {
            index += 1
        }
        return false
    }

    /// Attributes and their values; false once the tag closes.
    mutating func scanInsideTag() -> Bool {
        let char = chars[index]
        if char == ">" {
            index += 1
            return false
        }
        if char == "\"" || char == "'" {
            let end = closing(of: SyntaxLanguage.Quote(String(char)), from: index + 1) ?? chars.count
            emit(.string, index, end)
            index = end
        } else if isIdentifierStart(char) {
            let start = index
            while index < chars.count, isIdentifierPart(chars[index]) || chars[index] == ":" { index += 1 }
            emit(.type, start, index)
        } else {
            index += 1
        }
        return true
    }
}
