import Foundation

/// Parses `git worktree list --porcelain` into `[Worktree]`.
///
/// Porcelain entries are blank-line separated. Each entry starts with a
/// `worktree <path>` line, optionally followed by `HEAD <sha>`,
/// `branch refs/heads/<name>`, `detached`, `bare`, `locked [reason]`,
/// `prunable <reason>`. The first entry is the repository's primary checkout.
public enum WorktreeListParser {
    public static func parse(_ output: String) -> [Worktree] {
        var worktrees: [Worktree] = []

        var path: String?
        var head = ""
        var branch: String?
        var isBare = false
        var isDetached = false
        var isLocked = false

        func flush() {
            guard let path else { reset(); return }
            worktrees.append(
                Worktree(
                    path: path,
                    branch: branch,
                    head: head,
                    isPrimary: worktrees.isEmpty,
                    isBare: isBare,
                    isDetached: isDetached,
                    isLocked: isLocked
                )
            )
            reset()
        }

        func reset() {
            path = nil
            head = ""
            branch = nil
            isBare = false
            isDetached = false
            isLocked = false
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.isEmpty {
                flush()
                continue
            }
            if let value = value(of: "worktree", in: line) {
                // A new `worktree` line without a separating blank closes the prior entry.
                if path != nil { flush() }
                path = value
            } else if let value = value(of: "HEAD", in: line) {
                head = value
            } else if let value = value(of: "branch", in: line) {
                branch = shortBranchName(value)
            } else if line == "bare" {
                isBare = true
            } else if line == "detached" {
                isDetached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                isLocked = true
            }
            // `prunable` and any unknown keys are ignored.
        }
        flush()
        return worktrees
    }

    /// If `line` is `"<key> <value>"`, return `value`; otherwise `nil`.
    private static func value(of key: String, in line: String) -> String? {
        let prefix = key + " "
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func shortBranchName(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return ref
    }
}
