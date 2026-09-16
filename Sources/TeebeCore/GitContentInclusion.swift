import Foundation

/// Confirms that every changed path coexisted in the target, now or in its history.
/// Squash merges need content evidence because they do not retain branch ancestry.
/// Later target edits do not undo historical inclusion; a new branch tip is checked afresh.
/// This reads trees only, without creating commits, running merge drivers or using a network.
struct GitContentInclusion {
    /// How many historical revisions may be compared against the branch tip.
    /// Proposing is cheap, proving costs a tree comparison each, so the walk
    /// stays bounded and an exhausted budget simply confirms nothing.
    private static let confirmationLimit = 20

    let git: GitClient

    func containsChanges(from head: String, in target: String, repoPath: String) async throws -> Bool {
        let bases = try await run(["merge-base", "--all", head, target], in: repoPath)
        if bases.exitCode == 1 { return false }
        guard bases.succeeded else { throw CleanupError.gitFailed }
        let commits = bases.stdoutString.split(whereSeparator: \.isWhitespace)
        guard commits.count == 1, let base = commits.first else { return false }
        let changes = try await diff(String(base), head, in: repoPath)
        // Reaching here means the branch is not an ancestor of the target, so its
        // commits are unmerged. A branch that adds then deletes a file, or edits
        // then reverts one, contributes no content: there is nothing to confirm.
        guard !changes.isEmpty else { return false }
        var desired: [Data: Version] = [:]
        for change in changes {
            guard desired.updateValue(change.new, forKey: change.path) == nil else { throw CleanupError.gitFailed }
        }
        let different = try await diff(head, target, in: repoPath)
        let mismatches = Set(different.map(\.path)).intersection(desired.keys)
        if mismatches.isEmpty { return true }
        // Pass filenames literally, including leading dashes and pathspec metacharacters.
        // Non-UTF8 names still get the exact current-tree check above; do not convert lossily.
        let paths = desired.keys.compactMap { String(data: $0, encoding: .utf8) }
        guard paths.count == desired.count,
              paths.reduce(0, { $0 + $1.utf8.count + 1 }) < 64_000 else { return false }
        // Walk the whole reachable history, not just the first-parent chain: a
        // squash commit usually lands on an integration branch that reaches the
        // compared branch through a merge commit, so it is never a first parent.
        let history = try await run([
            "--literal-pathspecs", "log", "--full-history",
            "--format=%x00%H", "-z", "--raw", "--no-abbrev", "--no-renames",
            "--no-ext-diff", "--no-textconv", "--diff-merges=first-parent",
            "--max-count=1000", "\(base)..\(target)", "--"
        ] + paths, in: repoPath)
        guard history.succeeded else { throw CleanupError.gitFailed }
        let candidates = try Self.candidates(history.standardOutput, desired: desired)
        for candidate in candidates.prefix(Self.confirmationLimit) {
            // Proof, not a guess: every desired path must match this revision
            // exactly, including deletions and file modes.
            if try await diff(candidate, head, in: repoPath, limitedTo: paths).isEmpty { return true }
        }
        return false
    }

    private struct Version: Equatable {
        let mode: String
        let object: String
    }

    private struct Change {
        let path: Data
        let old: Version
        let new: Version
    }

    private func diff(
        _ from: String, _ to: String, in path: String, limitedTo paths: [String] = []
    ) async throws -> [Change] {
        let result = try await run([
            "--literal-pathspecs",
            "diff-tree", "--no-commit-id", "-r", "--raw", "--no-abbrev", "-z", "--no-renames",
            "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", from, to, "--"
        ] + paths, in: path)
        guard result.succeeded else { throw CleanupError.gitFailed }
        let tokens = result.standardOutput.split(separator: 0).map { Data($0) }
        guard tokens.count.isMultiple(of: 2) else { throw CleanupError.gitFailed }
        return try stride(from: 0, to: tokens.count, by: 2).map {
            try Self.change(header: tokens[$0], path: tokens[$0 + 1])
        }
    }

    private static func change(header: Data, path: Data) throws -> Change {
        guard let text = String(data: header, encoding: .utf8) else { throw CleanupError.gitFailed }
        let fields = text.trimmingCharacters(in: .newlines).split(separator: " ")
        guard fields.count == 5, fields[0].first == ":" else { throw CleanupError.gitFailed }
        return Change(path: path,
                      old: Version(mode: String(fields[0].dropFirst()), object: String(fields[2])),
                      new: Version(mode: String(fields[1]), object: String(fields[3])))
    }

    /// Revisions worth an exact comparison, most recent first: each one touched at
    /// least one desired path and set every path it touched to the desired version.
    /// A revision that rewrites a desired path to something else cannot match, so it
    /// is dropped here rather than costing a tree comparison.
    private static func candidates(_ data: Data, desired: [Data: Version]) throws -> [String] {
        let tokens = data.split(separator: 0).map { Data($0) }
        var result: [String] = []
        var revision: String?
        var touched = false
        var plausible = false
        var index = 0
        while index < tokens.count {
            try Task.checkCancellation()
            let token = tokens[index]
            guard let text = String(data: token, encoding: .utf8) else { throw CleanupError.gitFailed }
            let header = text.trimmingCharacters(in: .newlines)
            if header.first == ":" {
                guard revision != nil, index + 1 < tokens.count else { throw CleanupError.gitFailed }
                let change = try change(header: token, path: tokens[index + 1])
                if let wanted = desired[change.path] {
                    touched = true
                    if change.new != wanted { plausible = false }
                }
                index += 2
            } else {
                guard [40, 64].contains(header.count), header.allSatisfy(\.isHexDigit) else {
                    throw CleanupError.gitFailed
                }
                if let revision, touched, plausible { result.append(revision) }
                revision = header
                touched = false
                plausible = true
                index += 1
            }
        }
        if let revision, touched, plausible { result.append(revision) }
        return result
    }

    private func run(_ arguments: [String], in path: String) async throws -> GitInvocationResult {
        try Task.checkCancellation()
        return try await git.run(arguments, in: path)
    }
}
