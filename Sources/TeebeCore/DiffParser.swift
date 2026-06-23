import Foundation

/// Parses unified `git diff` output into `[DiffFile]`, handling modifications,
/// additions, deletions, renames/copies, and binary files.
public enum DiffParser {
    public static func parse(_ output: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: Mutable?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func closeHunk() {
            if let hunk = currentHunk {
                current?.hunks.append(hunk)
                currentHunk = nil
            }
        }
        func closeFile() {
            closeHunk()
            if let file = current { files.append(file.build()) }
            current = nil
        }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines {
            if line.hasPrefix("diff --git ") {
                closeFile()
                current = Mutable()
                if let (a, b) = parseDiffGitPaths(line) {
                    current?.oldPath = a
                    current?.newPath = b
                }
                continue
            }
            guard current != nil else { continue }

            if line.hasPrefix("new file mode") {
                current?.status = .added
            } else if line.hasPrefix("deleted file mode") {
                current?.status = .deleted
            } else if line.hasPrefix("rename from ") {
                current?.oldPath = String(line.dropFirst("rename from ".count))
                current?.status = .renamed
            } else if line.hasPrefix("rename to ") {
                current?.newPath = String(line.dropFirst("rename to ".count))
                current?.status = .renamed
            } else if line.hasPrefix("copy from ") {
                current?.oldPath = String(line.dropFirst("copy from ".count))
                current?.status = .copied
            } else if line.hasPrefix("copy to ") {
                current?.newPath = String(line.dropFirst("copy to ".count))
                current?.status = .copied
            } else if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                current?.isBinary = true
            } else if line.hasPrefix("--- ") {
                let p = path(fromMarker: line, prefix: "--- ")
                current?.oldPath = p
            } else if line.hasPrefix("+++ ") {
                let p = path(fromMarker: line, prefix: "+++ ")
                current?.newPath = p
            } else if line.hasPrefix("@@") {
                closeHunk()
                if let header = parseHunkHeader(line) {
                    oldLine = header.oldStart
                    newLine = header.newStart
                    currentHunk = header
                }
            } else if currentHunk != nil {
                guard let marker = line.first else {
                    // An empty string is the trailing newline split artifact or an
                    // inter-section separator — NOT a content line. (A genuinely
                    // blank context line is rendered as " ", a single space.)
                    continue
                }
                let content = String(line.dropFirst())
                switch marker {
                case "+":
                    currentHunk?.lines.append(DiffLine(kind: .addition, content: content, oldLineNumber: nil, newLineNumber: newLine))
                    newLine += 1
                case "-":
                    currentHunk?.lines.append(DiffLine(kind: .deletion, content: content, oldLineNumber: oldLine, newLineNumber: nil))
                    oldLine += 1
                case " ":
                    currentHunk?.lines.append(DiffLine(kind: .context, content: content, oldLineNumber: oldLine, newLineNumber: newLine))
                    oldLine += 1
                    newLine += 1
                case "\\":
                    // "\ No newline at end of file" — not a content line.
                    break
                default:
                    break
                }
            }
        }
        closeFile()
        return files
    }

    // MARK: - Helpers

    private struct Mutable {
        var oldPath: String?
        var newPath: String?
        var status: DiffFileStatus?
        var isBinary = false
        var hunks: [DiffHunk] = []

        func build() -> DiffFile {
            let resolvedStatus: DiffFileStatus
            if let status { resolvedStatus = status }
            else if oldPath == nil, newPath != nil { resolvedStatus = .added }
            else if newPath == nil, oldPath != nil { resolvedStatus = .deleted }
            else { resolvedStatus = .modified }
            return DiffFile(oldPath: oldPath, newPath: newPath, status: resolvedStatus, isBinary: isBinary, hunks: hunks)
        }
    }

    /// Extract a path from a `--- a/x` / `+++ b/x` marker line. `/dev/null` → nil.
    private static func path(fromMarker line: String, prefix: String) -> String? {
        var value = String(line.dropFirst(prefix.count))
        // git appends a TAB delimiter after the path when the filename contains
        // spaces (e.g. `+++ b/my file.txt\t`). Strip it.
        if value.hasSuffix("\t") { value = String(value.dropLast()) }
        if value == "/dev/null" { return nil }
        if value.hasPrefix("a/") || value.hasPrefix("b/") { value = String(value.dropFirst(2)) }
        return Unquote.cQuoted(value)
    }

    /// Parse `diff --git a/old b/new`. Best-effort for the common (no-space) case.
    private static func parseDiffGitPaths(_ line: String) -> (String, String)? {
        let body = String(line.dropFirst("diff --git ".count))
        guard let range = body.range(of: " b/") else { return nil }
        var a = String(body[body.startIndex..<range.lowerBound])
        let b = String(body[range.upperBound...])
        if a.hasPrefix("a/") { a = String(a.dropFirst(2)) }
        return (Unquote.cQuoted(a), Unquote.cQuoted(b))
    }

    /// Parse `@@ -oldStart[,oldCount] +newStart[,newCount] @@ [section]`.
    private static func parseHunkHeader(_ line: String) -> DiffHunk? {
        guard let closing = line.range(of: " @@", options: [], range: line.index(line.startIndex, offsetBy: 2)..<line.endIndex) else {
            // Header without trailing section text: `@@ -1 +1 @@`
            return parseRanges(line)
        }
        let rangesPart = String(line[line.startIndex..<closing.upperBound])
        let section = String(line[closing.upperBound...]).trimmingCharacters(in: .whitespaces)
        var hunk = parseRanges(rangesPart)
        hunk?.header = section
        return hunk
    }

    private static func parseRanges(_ text: String) -> DiffHunk? {
        // text looks like "@@ -l,s +l,s @@"
        let inner = text.replacingOccurrences(of: "@@", with: "")
        let tokens = inner.split(separator: " ").map(String.init)
        var oldStart = 0, oldCount = 1, newStart = 0, newCount = 1
        for token in tokens {
            if token.hasPrefix("-") {
                let (s, c) = parsePair(String(token.dropFirst()))
                oldStart = s; oldCount = c
            } else if token.hasPrefix("+") {
                let (s, c) = parsePair(String(token.dropFirst()))
                newStart = s; newCount = c
            }
        }
        return DiffHunk(oldStart: oldStart, oldCount: oldCount, newStart: newStart, newCount: newCount)
    }

    private static func parsePair(_ token: String) -> (Int, Int) {
        let parts = token.split(separator: ",").map(String.init)
        let start = parts.first.flatMap(Int.init) ?? 0
        let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
        return (start, count)
    }
}
