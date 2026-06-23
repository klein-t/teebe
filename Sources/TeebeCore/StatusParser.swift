import Foundation

/// Parses `git status --porcelain=v2 --branch -z` into a `StatusResult`.
///
/// With `-z`, every record is NUL-terminated (instead of LF), and rename/copy
/// entries (`2 ...`) carry their original path as an *extra* NUL-separated token
/// immediately after the record. Header lines begin with `# `.
public enum StatusParser {
    public static func parse(_ output: String) -> StatusResult {
        // Split into NUL-delimited tokens. Each token is one porcelain "line",
        // except a `2` (rename/copy) record is followed by its origPath token.
        let tokens = output.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)

        var result = StatusResult()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            index += 1
            if token.isEmpty { continue }

            let kind = token.first!
            switch kind {
            case "#":
                parseHeader(token, into: &result)
            case "1":
                if let change = parseOrdinary(token) { result.changes.append(change) }
            case "2":
                // The next token is the original path.
                let original = index < tokens.count ? tokens[index] : nil
                if original != nil { index += 1 }
                if let change = parseRename(token, originalPath: original) { result.changes.append(change) }
            case "u":
                if let change = parseUnmerged(token) { result.changes.append(change) }
            case "?":
                let path = String(token.dropFirst(2))
                result.changes.append(FileChange(path: path, worktreeStatus: .untracked))
            case "!":
                let path = String(token.dropFirst(2))
                result.changes.append(FileChange(path: path, worktreeStatus: .ignored))
            default:
                break
            }
        }
        return result
    }

    // MARK: Headers

    private static func parseHeader(_ token: String, into result: inout StatusResult) {
        // e.g. "# branch.oid <sha>", "# branch.head <name>", "# branch.ab +1 -2"
        let body = token.dropFirst(2) // drop "# "
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        guard let key = parts.first else { return }
        let value = parts.count > 1 ? parts[1] : ""
        switch key {
        case "branch.oid":
            result.oid = value == "(initial)" ? nil : value
        case "branch.head":
            if value == "(detached)" {
                result.isDetached = true
                result.branch = nil
            } else {
                result.branch = value
            }
        case "branch.upstream":
            result.upstream = value.isEmpty ? nil : value
        case "branch.ab":
            let ab = value.split(separator: " ").map(String.init)
            for field in ab {
                if field.hasPrefix("+") { result.ahead = Int(field.dropFirst()) ?? 0 }
                else if field.hasPrefix("-") { result.behind = Int(field.dropFirst()) ?? 0 }
            }
        default:
            break
        }
    }

    // MARK: Entries

    /// `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`
    private static func parseOrdinary(_ token: String) -> FileChange? {
        let fields = token.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 9 else { return nil }
        let (x, y) = statusChars(fields[1])
        return FileChange(path: fields[8], indexStatus: x, worktreeStatus: y)
    }

    /// `2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <path>` (+ origPath token)
    private static func parseRename(_ token: String, originalPath: String?) -> FileChange? {
        let fields = token.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 10 else { return nil }
        let (x, y) = statusChars(fields[1])
        return FileChange(path: fields[9], originalPath: originalPath, indexStatus: x, worktreeStatus: y)
    }

    /// `u <xy> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>` (unmerged/conflict)
    private static func parseUnmerged(_ token: String) -> FileChange? {
        let fields = token.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 11 else { return nil }
        return FileChange(path: fields[10], indexStatus: .conflicted, worktreeStatus: .conflicted)
    }

    /// Decode the two-character `XY` field into (index, worktree) statuses.
    private static func statusChars(_ xy: String) -> (ChangeStatus, ChangeStatus) {
        let chars = Array(xy)
        let x = !chars.isEmpty ? (ChangeStatus(porcelainCode: chars[0]) ?? .unmodified) : .unmodified
        let y = chars.count > 1 ? (ChangeStatus(porcelainCode: chars[1]) ?? .unmodified) : .unmodified
        return (x, y)
    }
}
