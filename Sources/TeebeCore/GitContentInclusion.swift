import Foundation

/// Confirms that every changed path coexisted in the target, now or in its history.
/// Squash merges need content evidence because they do not retain branch ancestry.
/// Failing that, it confirms that every commit of the branch landed in the target
/// one by one (see `commitsAreUpstream`).
/// Later target edits do not undo historical inclusion; a new branch tip is checked afresh.
/// This reads trees only, without creating commits, running merge drivers or using a network.
struct GitContentInclusion {
    /// How many historical revisions may be compared against the branch tip.
    /// Proposing is cheap, proving costs a tree comparison each, so the walk
    /// stays bounded and an exhausted budget simply confirms nothing.
    private static let confirmationLimit = 20
    /// How many commits each side may have for the per-commit check, which hashes
    /// the patch of every one of them. Matches the history walk above; beyond it
    /// nothing is confirmed.
    private static let commitLimit = 1000

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
        let desired = Dictionary(changes.map { ($0.path, $0.new) }, uniquingKeysWith: { first, _ in first })
        guard desired.count == changes.count else { throw CleanupError.gitFailed }
        let different = try await diff(head, target, in: repoPath)
        let mismatches = Set(different.map(\.path)).intersection(desired.keys)
        if mismatches.isEmpty { return true }
        // Pass filenames literally, including leading dashes and pathspec metacharacters.
        // Non-UTF8 names still get the exact current-tree check above; do not convert lossily.
        let paths = desired.keys.compactMap { String(data: $0, encoding: .utf8) }
        guard paths.count == desired.count,
              paths.reduce(0, { $0 + $1.utf8.count + 1 }) < 64_000 else {
            return try await commitsAreUpstream(base: String(base), head: head, target: target, repoPath: repoPath)
        }
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
            let unmatched = try await diff(candidate, head, in: repoPath, limitedTo: paths)
            if unmatched.isEmpty { return true }
        }
        return try await commitsAreUpstream(base: String(base), head: head, target: target, repoPath: repoPath)
    }

    /// Whether every commit of the branch has a commit with the same patch in the
    /// target since their merge base. This covers a branch landed
    /// commit by commit among other work (picked, rebased or squashed separately),
    /// where no single target revision holds all of its changes at once.
    ///
    /// It is deliberately narrow, because a confirmed branch may be deleted:
    /// - the branch must have at least one commit and no merge commits, so its
    ///   content is exactly the sum of the patches checked here (a merge could
    ///   carry a conflict resolution or other content no patch accounts for);
    /// - every one of those commits must be matched; one unmatched commit, or one
    ///   that landed differently (a changed conflict resolution changes its patch),
    ///   confirms nothing;
    /// - both sides are bounded by `commitLimit`.
    /// A commit is matched only by the same change to the same files, whitespace
    /// included (Git's own patch-id ignores it, so a re-indent would match a
    /// different re-indent). An empty commit has no change to match.
    private func commitsAreUpstream(base: String, head: String, target: String, repoPath: String) async throws -> Bool {
        let own = try await run(["rev-list", "--parents", "--max-count=\(Self.commitLimit + 1)", "\(base)..\(head)"],
                                in: repoPath)
        guard own.succeeded else { throw CleanupError.gitFailed }
        let commits = own.stdoutString.split(separator: "\n")
        // One parent each: a merge has more, a root commit has none.
        guard !commits.isEmpty, commits.count <= Self.commitLimit,
              commits.allSatisfy({ $0.split(separator: " ").count == 2 }) else { return false }
        let upstream = try await run(["rev-list", "--count", "\(base)..\(target)"], in: repoPath)
        guard upstream.succeeded,
              let count = Int(upstream.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw CleanupError.gitFailed }
        guard count <= Self.commitLimit else { return false }
        let mine = try await patches("\(base)..\(head)", in: repoPath)
        let landed = Set(try await patches("\(base)..\(target)", in: repoPath).compactMap { $0 })
        return mine.count == commits.count && mine.allSatisfy { $0.map(landed.contains) ?? false }
    }

    /// The patch of each non-merge commit in `range`, newest first, or nil for a
    /// commit that changes nothing. Whitespace is kept; only what differs when the
    /// same change is applied elsewhere is dropped: hunk line numbers and function
    /// context, and the blob ids of text files (binary files keep theirs, as their
    /// patch says nothing else about the content).
    private func patches(_ range: String, in repoPath: String) async throws -> [Data?] {
        let log = try await run([
            // Blank context lines keep their leading space, so empty lines only separate.
            "-c", "diff.suppressBlankEmpty=false",
            "log", "-p", "--no-merges", "--format=%x00%H", "--no-color", "--no-show-signature",
            "--full-index", "--no-renames", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none",
            "--max-count=\(Self.commitLimit)", range
        ], in: repoPath)
        guard log.succeeded else { throw CleanupError.gitFailed }
        var result: [Data?] = []
        var patch: [Data] = []
        var file: [Data] = []
        var started = false
        func endFile() {
            let binary = file.contains { $0.starts(with: Data("Binary files ".utf8)) }
            for line in file {
                guard !binary, line.starts(with: Data("index ".utf8)) else { patch.append(line); continue }
                // "index <old>..<new>[ <mode>]": keep only the mode.
                let fields = line.split(separator: UInt8(ascii: " "))
                patch.append(Data("index".utf8) + (fields.count == 3 ? Data(" ".utf8) + fields[2] : Data()))
            }
            file = []
        }
        func endCommit() {
            endFile()
            if started { result.append(patch.isEmpty ? nil : Data(patch.joined(separator: [10]))) }
            patch = []
        }
        for line in log.standardOutput.split(separator: 10).map({ Data($0) }) {
            try Task.checkCancellation()
            if line.first == 0 {
                endCommit()
                started = true
            } else if line.starts(with: Data("diff ".utf8)) {
                endFile()
                file = [line]
            } else if line.starts(with: Data("@@".utf8)), !file.isEmpty {
                file.append(Data("@@".utf8))
            } else if !file.isEmpty {
                file.append(line)
            } else {
                throw CleanupError.gitFailed
            }
        }
        endCommit()
        return result
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
