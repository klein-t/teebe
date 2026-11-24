import Testing
@testable import TeebeCore

@Suite("SyntaxTokenizer")
struct SyntaxTokenizerTests {
    /// The text of each token of `kind`, in order.
    func texts(_ line: String, _ path: String, _ kind: SyntaxTokenKind, state: SyntaxState = .normal) throws -> [String] {
        let language = try #require(SyntaxLanguage.forPath(path))
        let chars = Array(line)
        return SyntaxTokenizer.tokenize(line, language: language, state: state).tokens
            .filter { $0.kind == kind }
            .map { String(chars[$0.range]) }
    }

    @Test("picks languages by extension and well-known name, unknown stays plain")
    func languageLookup() {
        #expect(SyntaxLanguage.forPath("Sources/App.swift")?.name == "Swift")
        #expect(SyntaxLanguage.forPath("web/App.TSX")?.name == "TSX")
        #expect(SyntaxLanguage.forPath("Gemfile")?.name == "Ruby")
        #expect(SyntaxLanguage.forPath("x/.zshrc")?.name == "Shell")
        #expect(SyntaxLanguage.forPath("notes.txt") == nil)
        #expect(SyntaxLanguage.forPath("Makefile") == nil)
        for path in ["a.py", "a.js", "a.ts", "a.jsx", "a.json", "a.yaml", "a.toml", "a.go", "a.rs", "a.java",
                     "a.kt", "a.c", "a.cpp", "a.m", "a.rb", "a.sh", "a.html", "a.css", "a.md", "a.sql"] {
            #expect(SyntaxLanguage.forPath(path) != nil, "\(path)")
        }
    }

    @Test("Swift: keywords, types, strings, numbers, comments, attributes")
    func swift() throws {
        let line = #"@MainActor let count: Int = 0x1F + 2.5 // "not a string""#
        #expect(try texts(line, "a.swift", .keyword) == ["@MainActor", "let"])
        #expect(try texts(line, "a.swift", .type) == ["Int"])
        #expect(try texts(line, "a.swift", .number) == ["0x1F", "2.5"])
        #expect(try texts(line, "a.swift", .comment) == [#"// "not a string""#])
        #expect(try texts(line, "a.swift", .string).isEmpty)
        #expect(try texts(#"let s = "a \"q\" b""#, "a.swift", .string) == [#""a \"q\" b""#])
    }

    @Test("Python: triple-quoted strings carry over lines")
    func pythonMultiline() throws {
        let python = try #require(SyntaxLanguage.forPath("a.py"))
        let first = SyntaxTokenizer.tokenize(#"doc = """start"#, language: python)
        #expect(first.state != .normal)
        let second = SyntaxTokenizer.tokenize(#"end""" if x else None  # done"#, language: python, state: first.state)
        #expect(second.state == .normal)
        #expect(second.tokens.first == SyntaxToken(.string, 0..<6))
        #expect(second.tokens.contains { $0.kind == .keyword })
        #expect(second.tokens.last?.kind == .comment)
    }

    @Test("block comments carry over lines and close")
    func blockComment() throws {
        let javaScript = try #require(SyntaxLanguage.forPath("a.js"))
        let open = SyntaxTokenizer.tokenize("const a = 1 /* begin", language: javaScript)
        let middle = SyntaxTokenizer.tokenize("still a comment", language: javaScript, state: open.state)
        #expect(middle.tokens == [SyntaxToken(.comment, 0..<15)])
        let close = SyntaxTokenizer.tokenize("end */ return a", language: javaScript, state: middle.state)
        #expect(close.state == .normal)
        #expect(close.tokens.map(\.kind) == [.comment, .keyword])
    }

    @Test("JSON keys read as types, values as strings")
    func json() throws {
        let line = #"  "name": "teebe", "count": 3, "ok": true"#
        #expect(try texts(line, "a.json", .type) == [#""name""#, #""count""#, #""ok""#])
        #expect(try texts(line, "a.json", .string) == [#""teebe""#])
        #expect(try texts(line, "a.json", .number) == ["3"])
        #expect(try texts(line, "a.json", .keyword) == ["true"])
    }

    @Test("YAML and TOML keys, comments only after a space")
    func keyValue() throws {
        #expect(try texts("  - name: build # step", "ci.yml", .type) == ["name"])
        #expect(try texts("  - name: build # step", "ci.yml", .comment) == ["# step"])
        #expect(try texts("url: http://x#y", "ci.yml", .comment).isEmpty)
        #expect(try texts("[tool.swift]", "a.toml", .keyword) == ["[tool.swift]"])
        #expect(try texts(#"version = "1.2""#, "a.toml", .type) == ["version"])
    }

    @Test("Markdown: headings, code, fences, links")
    func markdown() throws {
        #expect(try texts("## Install", "a.md", .keyword) == ["## Install"])
        #expect(try texts("Run `swift build` then [docs](https://x.y)", "a.md", .string) == ["`swift build`"])
        #expect(try texts("Run `swift build` then [docs](https://x.y)", "a.md", .type) == ["(https://x.y)"])
        let markdown = try #require(SyntaxLanguage.forPath("a.md"))
        let fence = SyntaxTokenizer.tokenize("```swift", language: markdown)
        #expect(fence.state == .fence)
        let inside = SyntaxTokenizer.tokenize("# not a heading", language: markdown, state: fence.state)
        #expect(inside.tokens == [SyntaxToken(.string, 0..<15)])
    }

    @Test("HTML tags, attributes, and Rust lifetimes vs. characters")
    func markupAndRust() throws {
        let html = #"<a href="/x" class='y'>it's</a>"#
        #expect(try texts(html, "a.html", .keyword) == ["a", "a"])
        #expect(try texts(html, "a.html", .type) == ["href", "class"])
        #expect(try texts(html, "a.html", .string) == [#""/x""#, "'y'"])
        #expect(try texts("fn f<'a>(x: &'a str) -> char { 'z' }", "a.rs", .string) == ["'z'"])
    }

    @Test("SQL keywords ignore case; shell variables")
    func sqlAndShell() throws {
        #expect(try texts("SELECT id FROM users -- all", "a.sql", .keyword) == ["SELECT", "FROM"])
        #expect(try texts(#"echo "$HOME" ${PATH} # note"#, "a.sh", .type) == ["${PATH}"])
        #expect(try texts(#"echo "$HOME" ${PATH} # note"#, "a.sh", .comment) == ["# note"])
    }

    @Test("odd input never crashes and never splits a character")
    func oddInput() throws {
        let swift = try #require(SyntaxLanguage.forPath("a.swift"))
        let lines = [
            "", "\t", "let a = 1\r", "let s = \"e\u{301}\u{301}\" // 👩‍👩‍👧 café",
            "\u{FFFD}\u{FFFD}let\u{FFFD}", "x\u{0}y", String(repeating: "\"", count: 999),
            String(repeating: "/*", count: 500), "let 👍🏽 = \"🇮🇹\"\r\n", "'", "\\", "@", "#", "$"
        ]
        for line in lines {
            let count = line.count
            for language in SyntaxLanguage.byExtension.values {
                let tokens = SyntaxTokenizer.tokenize(line, language: language).tokens
                for token in tokens {
                    #expect(token.range.lowerBound >= 0 && token.range.upperBound <= count)
                    #expect(!token.range.isEmpty)
                }
                #expect(zip(tokens, tokens.dropFirst()).allSatisfy { $0.range.upperBound <= $1.range.lowerBound })
            }
        }
        // Emoji and combining marks are whole characters inside the string token.
        let tokens = SyntaxTokenizer.tokenize("let s = \"e\u{301}👩‍👩‍👧\"", language: swift).tokens
        #expect(tokens.last == SyntaxToken(.string, 8..<12))
    }

    @Test("binary-looking and overlong lines stay plain, quickly")
    func bounded() throws {
        let swift = try #require(SyntaxLanguage.forPath("a.swift"))
        #expect(SyntaxTokenizer.tokenize("let\u{0}x = 1", language: swift).tokens.isEmpty)
        let long = String(repeating: "let x = 1; ", count: 1000)
        #expect(SyntaxTokenizer.tokenize(long, language: swift).tokens.isEmpty)
        // An open block comment survives a skipped line instead of being forgotten.
        let state = SyntaxTokenizer.tokenize("/* open", language: swift).state
        #expect(SyntaxTokenizer.tokenize(long, language: swift, state: state).state == state)
        // Worst case at the limit: many unclosed quotes, still fast.
        let quotes = String(repeating: "'\"", count: SyntaxTokenizer.maxLineBytes / 2)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for language in SyntaxLanguage.byExtension.values {
                _ = SyntaxTokenizer.tokenize(quotes, language: language)
            }
        }
        #expect(elapsed < .seconds(2))
    }
}
