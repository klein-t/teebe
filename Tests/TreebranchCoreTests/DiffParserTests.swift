import Testing
@testable import TreebranchCore

@Suite("DiffParser")
struct DiffParserTests {
    @Test("modified file: hunk with add/remove/context and line numbers")
    func modified() {
        let diff = """
        diff --git a/tracked.txt b/tracked.txt
        index 83db48f..a597da7 100644
        --- a/tracked.txt
        +++ b/tracked.txt
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2 CHANGED
         line3
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        let file = files[0]
        #expect(file.status == .modified)
        #expect(file.oldPath == "tracked.txt")
        #expect(file.newPath == "tracked.txt")
        #expect(file.isBinary == false)
        #expect(file.hunks.count == 1)

        let hunk = file.hunks[0]
        #expect(hunk.oldStart == 1 && hunk.oldCount == 3)
        #expect(hunk.newStart == 1 && hunk.newCount == 3)
        #expect(hunk.lines.count == 4)

        #expect(hunk.lines[0].kind == .context)
        #expect(hunk.lines[0].oldLineNumber == 1 && hunk.lines[0].newLineNumber == 1)

        #expect(hunk.lines[1].kind == .deletion)
        #expect(hunk.lines[1].content == "line2")
        #expect(hunk.lines[1].oldLineNumber == 2 && hunk.lines[1].newLineNumber == nil)

        #expect(hunk.lines[2].kind == .addition)
        #expect(hunk.lines[2].content == "line2 CHANGED")
        #expect(hunk.lines[2].oldLineNumber == nil && hunk.lines[2].newLineNumber == 2)

        #expect(file.addedCount == 1)
        #expect(file.removedCount == 1)
    }

    @Test("added file: /dev/null old side")
    func added() {
        let diff = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..abc1234
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,2 @@
        +hello
        +world
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].status == .added)
        #expect(files[0].oldPath == nil)
        #expect(files[0].newPath == "new.txt")
        #expect(files[0].addedCount == 2)
    }

    @Test("deleted file: /dev/null new side")
    func deleted() {
        let diff = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index abc1234..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,2 +0,0 @@
        -hello
        -world
        """
        let files = DiffParser.parse(diff)
        #expect(files[0].status == .deleted)
        #expect(files[0].oldPath == "gone.txt")
        #expect(files[0].newPath == nil)
        #expect(files[0].removedCount == 2)
    }

    @Test("rename with 100% similarity: no hunks")
    func rename() {
        let diff = """
        diff --git a/torename.txt b/renamed.txt
        similarity index 100%
        rename from torename.txt
        rename to renamed.txt
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 1)
        #expect(files[0].status == .renamed)
        #expect(files[0].oldPath == "torename.txt")
        #expect(files[0].newPath == "renamed.txt")
        #expect(files[0].hunks.isEmpty)
    }

    @Test("binary file flagged, no hunks")
    func binary() {
        let diff = """
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..abc1234
        Binary files /dev/null and b/img.png differ
        """
        let files = DiffParser.parse(diff)
        #expect(files[0].isBinary == true)
        #expect(files[0].hunks.isEmpty)
        #expect(files[0].status == .added)
    }

    @Test("multiple files in one diff")
    func multiple() {
        let diff = """
        diff --git a/a.txt b/a.txt
        index 111..222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -a
        +A
        diff --git a/b.txt b/b.txt
        index 333..444 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -b
        +B
        """
        let files = DiffParser.parse(diff)
        #expect(files.count == 2)
        #expect(files[0].displayPath == "a.txt")
        #expect(files[1].displayPath == "b.txt")
    }

    @Test("empty output yields no files")
    func empty() {
        #expect(DiffParser.parse("").isEmpty)
    }

    @Test("no phantom trailing context line when diff ends with a newline")
    func noPhantomTrailingLine() {
        // Real git output ends with a trailing newline → a trailing empty split token.
        let diff = "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n line1\n-line2\n+LINE2\n"
        let hunk = DiffParser.parse(diff)[0].hunks[0]
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines.contains { $0.kind == .context && $0.content.isEmpty } == false)
    }

    @Test("path with spaces: trailing TAB delimiter stripped")
    func pathWithSpaces() {
        let diff = "diff --git a/my file.txt b/my file.txt\nindex 1..2 100644\n--- a/my file.txt\t\n+++ b/my file.txt\t\n@@ -1 +1 @@\n-a\n+b\n"
        let file = DiffParser.parse(diff)[0]
        #expect(file.newPath == "my file.txt")
        #expect(file.oldPath == "my file.txt")
    }

    @Test("genuinely blank context line is preserved")
    func blankContextLine() {
        // A blank line in the file is rendered as a single space in the diff.
        let diff = "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n@@ -1,3 +1,3 @@\n line1\n \n+added\n"
        let hunk = DiffParser.parse(diff)[0].hunks[0]
        // context "line1", context "" (the blank line), addition "added"
        #expect(hunk.lines.count == 3)
        #expect(hunk.lines[1].kind == .context)
        #expect(hunk.lines[1].content == "")
    }
}

@Suite("Unquote")
struct UnquoteTests {
    @Test("C-quoted UTF-8 octal escapes are decoded")
    func octal() {
        #expect(Unquote.cQuoted("\"src/caf\\303\\251.txt\"") == "src/café.txt")
    }

    @Test("escaped control characters decoded")
    func escapes() {
        #expect(Unquote.cQuoted("\"a\\tb\"") == "a\tb")
    }

    @Test("unquoted input returned unchanged")
    func passthrough() {
        #expect(Unquote.cQuoted("plain/path.txt") == "plain/path.txt")
    }
}
