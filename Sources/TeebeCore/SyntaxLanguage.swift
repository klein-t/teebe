import Foundation

/// The rules `SyntaxTokenizer` applies to one language, picked by file name.
public struct SyntaxLanguage: Sendable {
    public enum Family: Sendable, Equatable {
        case code, json, keyValue, css, markdown, markup
    }

    public struct Delimiters: Sendable {
        let open: [Character]
        let close: [Character]
        init(_ open: String, _ close: String) {
            self.open = Array(open)
            self.close = Array(close)
        }
    }

    public struct Quote: Sendable {
        let open: [Character]
        let close: [Character]
        var escapes = true
        var multiline = false
        /// A one-character literal only (Rust `'a'`), so a lifetime stays plain.
        var shortLiteral = false

        init(_ delimiter: String, escapes: Bool = true, multiline: Bool = false, shortLiteral: Bool = false) {
            open = Array(delimiter)
            close = Array(delimiter)
            self.escapes = escapes
            self.multiline = multiline
            self.shortLiteral = shortLiteral
        }
    }

    public private(set) var name: String
    var family: Family = .code
    var lineComments: [[Character]] = []
    var blockComments: [Delimiters] = []
    /// Longest delimiter first, so `"""` wins over `"`.
    var quotes: [Quote] = []
    var keywords: Set<String> = []
    var types: Set<String> = []
    var caseInsensitive = false
    var capitalizedTypes = false
    var identifierExtras: Set<Character> = []
    var atWords: SyntaxTokenKind?
    var hashDirectives = false
    var dollarVariables = false
    var jsxTags = false
    /// `#` starts a comment only at the start or after a space (shell, YAML).
    var commentNeedsSpaceBefore = false

    init(_ name: String) { self.name = name }

    /// The language for a file, by extension or well-known name; nil stays plain.
    public static func forPath(_ path: String) -> SyntaxLanguage? {
        let name = (path as NSString).lastPathComponent.lowercased()
        if let byName = byFileName[name] { return byName }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? nil : byExtension[ext]
    }

    static let byFileName: [String: SyntaxLanguage] = [
        "gemfile": ruby, "rakefile": ruby, "podfile": ruby, "fastfile": ruby,
        ".bashrc": shell, ".zshrc": shell, ".profile": shell, ".bash_profile": shell, ".zprofile": shell
    ]

    static let byExtension: [String: SyntaxLanguage] = {
        var map: [String: SyntaxLanguage] = [:]
        func add(_ language: SyntaxLanguage, _ extensions: String) {
            for ext in extensions.split(separator: " ") { map[String(ext)] = language }
        }
        add(swift, "swift")
        add(python, "py pyi pyw")
        add(javaScript, "js mjs cjs")
        add(typeScript, "ts mts cts")
        add(jsx, "jsx")
        add(tsx, "tsx")
        add(json, "json jsonc json5 jsonl")
        add(yaml, "yaml yml")
        add(toml, "toml")
        add(go, "go")
        add(rust, "rs")
        add(java, "java")
        add(kotlin, "kt kts")
        add(cFamily, "c h cc cpp cxx hpp hh hxx m mm")
        add(ruby, "rb rake gemspec")
        add(shell, "sh bash zsh ksh")
        add(markup, "html htm xhtml xml svg plist")
        add(css, "css scss less")
        add(markdown, "md markdown mdx")
        add(sql, "sql")
        return map
    }()

    // MARK: - Definitions

    private static func words(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }
    private static let cComments: [[Character]] = [Array("//")]
    private static let cBlock = [Delimiters("/*", "*/")]
    private static let hash: [[Character]] = [Array("#")]

    static let swift: SyntaxLanguage = {
        var lang = SyntaxLanguage("Swift")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\"\"\"", multiline: true), Quote("\"")]
        lang.keywords = words("""
            associatedtype class deinit enum extension fileprivate func import init inout internal let open operator \
            private precedencegroup protocol public rethrows static struct subscript typealias var break case catch \
            continue default defer do else fallthrough for guard if in repeat return throw switch where while as \
            false is nil self Self super throws true try async await actor some any nonisolated mutating override \
            final lazy weak unowned convenience required dynamic indirect optional get set willSet didSet consume \
            borrowing consuming sending macro package
            """)
        lang.capitalizedTypes = true
        lang.atWords = .keyword
        lang.hashDirectives = true
        return lang
    }()

    static let python: SyntaxLanguage = {
        var lang = SyntaxLanguage("Python")
        lang.lineComments = hash
        lang.quotes = [Quote("\"\"\"", multiline: true), Quote("'''", multiline: true), Quote("\""), Quote("'")]
        lang.keywords = words("""
            False None True and as assert async await break class continue def del elif else except finally for \
            from global if import in is lambda nonlocal not or pass raise return try while with yield match case \
            self cls
            """)
        lang.types = words("int float str bool list dict set tuple bytes object type complex frozenset")
        lang.capitalizedTypes = true
        lang.atWords = .keyword
        return lang
    }()

    static let javaScript: SyntaxLanguage = {
        var lang = SyntaxLanguage("JavaScript")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("`", multiline: true), Quote("\""), Quote("'")]
        lang.keywords = words("""
            break case catch class const continue debugger default delete do else export extends finally for \
            function if import in instanceof let new return super switch this throw try typeof var void while \
            with yield async await of static get set null undefined true false from as
            """)
        lang.capitalizedTypes = true
        lang.identifierExtras = ["$"]
        lang.atWords = .keyword
        return lang
    }()

    static let typeScript: SyntaxLanguage = {
        var lang = SyntaxLanguage(copying: javaScript, name: "TypeScript")
        lang.keywords.formUnion(words("""
            interface type enum implements namespace declare abstract readonly private protected public is keyof \
            infer never unknown any satisfies module
            """))
        lang.types = words("string number boolean object symbol bigint void")
        return lang
    }()

    static let jsx: SyntaxLanguage = {
        var lang = SyntaxLanguage(copying: javaScript, name: "JSX")
        lang.jsxTags = true
        return lang
    }()

    static let tsx: SyntaxLanguage = {
        var lang = SyntaxLanguage(copying: typeScript, name: "TSX")
        lang.jsxTags = true
        return lang
    }()

    static let json: SyntaxLanguage = {
        var lang = SyntaxLanguage("JSON")
        lang.family = .json
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\"")]
        lang.keywords = words("true false null")
        return lang
    }()

    static let yaml: SyntaxLanguage = {
        var lang = SyntaxLanguage("YAML")
        lang.family = .keyValue
        lang.lineComments = hash
        lang.commentNeedsSpaceBefore = true
        lang.quotes = [Quote("\""), Quote("'", escapes: false)]
        lang.keywords = words("true false null yes no on off")
        lang.caseInsensitive = true
        return lang
    }()

    static let toml: SyntaxLanguage = {
        var lang = SyntaxLanguage("TOML")
        lang.family = .keyValue
        lang.lineComments = hash
        lang.quotes = [Quote("\"\"\"", multiline: true), Quote("'''", escapes: false, multiline: true),
                       Quote("\""), Quote("'", escapes: false)]
        lang.keywords = words("true false")
        return lang
    }()

    static let go: SyntaxLanguage = {
        var lang = SyntaxLanguage("Go")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("`", escapes: false, multiline: true), Quote("\""), Quote("'")]
        lang.keywords = words("""
            break case chan const continue default defer else fallthrough for func go goto if import interface \
            map package range return select struct switch type var true false nil iota
            """)
        lang.types = words("""
            bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 \
            uint16 uint32 uint64 uintptr any
            """)
        return lang
    }()

    static let rust: SyntaxLanguage = {
        var lang = SyntaxLanguage("Rust")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\""), Quote("'", shortLiteral: true)]
        lang.keywords = words("""
            as async await break const continue crate dyn else enum extern false fn for if impl in let loop match \
            mod move mut pub ref return self Self static struct super trait true type unsafe use where while
            """)
        lang.types = words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str")
        lang.capitalizedTypes = true
        return lang
    }()

    static let java: SyntaxLanguage = {
        var lang = SyntaxLanguage("Java")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\"\"\"", multiline: true), Quote("\""), Quote("'")]
        lang.keywords = words("""
            abstract assert break case catch class const continue default do else enum extends final finally for \
            goto if implements import instanceof interface native new package private protected public return \
            static strictfp super switch synchronized this throw throws transient try volatile while true false \
            null var record sealed permits yield
            """)
        lang.types = words("boolean byte char short int long float double void")
        lang.capitalizedTypes = true
        lang.atWords = .keyword
        return lang
    }()

    static let kotlin: SyntaxLanguage = {
        var lang = SyntaxLanguage("Kotlin")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\"\"\"", multiline: true), Quote("\""), Quote("'")]
        lang.keywords = words("""
            as break class continue do else false for fun if in interface is null object package return super this \
            throw true try typealias typeof val var when while by catch constructor finally get import init set \
            where abstract annotation companion const data enum external final infix inline inner internal \
            lateinit open operator out override private protected public reified sealed suspend tailrec vararg
            """)
        lang.capitalizedTypes = true
        lang.atWords = .keyword
        return lang
    }()

    static let cFamily: SyntaxLanguage = {
        var lang = SyntaxLanguage("C")
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\""), Quote("'")]
        lang.keywords = words("""
            auto break case const continue default do else enum extern for goto if inline register restrict return \
            sizeof static struct switch typedef union volatile while catch class constexpr decltype delete explicit \
            export false friend mutable namespace new noexcept nullptr operator private protected public \
            static_assert template this throw true try typename using virtual override final nil YES NO self super \
            NULL
            """)
        lang.types = words("""
            void char short int long float double signed unsigned bool size_t ssize_t int8_t int16_t int32_t \
            int64_t uint8_t uint16_t uint32_t uint64_t id instancetype SEL BOOL
            """)
        lang.capitalizedTypes = true
        lang.atWords = .keyword
        lang.hashDirectives = true
        return lang
    }()

    static let ruby: SyntaxLanguage = {
        var lang = SyntaxLanguage("Ruby")
        lang.lineComments = hash
        lang.quotes = [Quote("\""), Quote("'")]
        lang.keywords = words("""
            BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module \
            next nil not or redo rescue retry return self super then true undef unless until when while yield \
            require require_relative attr_accessor attr_reader attr_writer private protected public lambda proc
            """)
        lang.capitalizedTypes = true
        lang.atWords = .type
        return lang
    }()

    static let shell: SyntaxLanguage = {
        var lang = SyntaxLanguage("Shell")
        lang.lineComments = hash
        lang.commentNeedsSpaceBefore = true
        lang.quotes = [Quote("\""), Quote("'", escapes: false)]
        lang.keywords = words("""
            if then else elif fi case esac for while until do done in function return exit local export readonly \
            declare unset shift break continue source alias echo set trap eval exec true false
            """)
        lang.dollarVariables = true
        return lang
    }()

    static let markup: SyntaxLanguage = {
        var lang = SyntaxLanguage("HTML")
        lang.family = .markup
        lang.blockComments = [Delimiters("<!--", "-->")]
        lang.identifierExtras = ["-"]
        return lang
    }()

    static let css: SyntaxLanguage = {
        var lang = SyntaxLanguage("CSS")
        lang.family = .css
        lang.lineComments = cComments
        lang.blockComments = cBlock
        lang.quotes = [Quote("\""), Quote("'")]
        lang.keywords = words("important inherit initial unset none auto")
        lang.identifierExtras = ["-"]
        lang.atWords = .keyword
        lang.dollarVariables = true
        return lang
    }()

    static let markdown: SyntaxLanguage = {
        var lang = SyntaxLanguage("Markdown")
        lang.family = .markdown
        lang.blockComments = [Delimiters("<!--", "-->")]
        return lang
    }()

    static let sql: SyntaxLanguage = {
        var lang = SyntaxLanguage("SQL")
        lang.lineComments = [Array("--")]
        lang.blockComments = cBlock
        lang.quotes = [Quote("'"), Quote("\"")]
        lang.keywords = words("""
            select from where and or not insert into values update set delete create table drop alter add index \
            primary key foreign references join left right inner outer full on as group by order having limit \
            offset union all distinct case when then else end null is in exists between like returning with \
            default constraint unique check view begin commit rollback transaction if asc desc cascade true false
            """)
        lang.types = words("""
            int integer bigint smallint text varchar char boolean bool date time timestamp timestamptz numeric \
            decimal real float double serial bigserial uuid json jsonb blob
            """)
        lang.caseInsensitive = true
        return lang
    }()

    private init(copying other: SyntaxLanguage, name: String) {
        self = other
        self.name = name
    }
}
