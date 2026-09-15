import Foundation

/// Recognizes squash/cherry-pick content without claiming a historical merge event.
/// Every path changed since the sole merge base must match the target exactly
/// (blob, mode, deletion). Later edits to those paths stay unconfirmed.
/// Reads trees only: no checkout, synthetic commits, merge drivers or network.
struct GitContentInclusion {
    let git: GitClient

    func containsChanges(from head: String, in target: String, repoPath: String) async throws -> Bool {
        let bases = try await run(["merge-base", "--all", head, target], in: repoPath)
        if bases.exitCode == 1 { return false } // Unrelated histories.
        guard bases.succeeded else { throw CleanupError.gitFailed }
        let commits = bases.stdoutString.split(whereSeparator: \.isWhitespace)
        guard commits.count == 1, let base = commits.first else { return false }
        let changed = try await changedPaths(String(base), head, in: repoPath)
        let different = try await changedPaths(head, target, in: repoPath)
        return changed.isDisjoint(with: different)
    }

    private func changedPaths(_ from: String, _ to: String, in path: String) async throws -> Set<Data> {
        let result = try await run([
            "diff-tree", "--no-commit-id", "-r", "--name-only", "-z", "--no-renames",
            "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", from, to, "--"
        ], in: path)
        guard result.succeeded else { throw CleanupError.gitFailed }
        // Keep raw pathname bytes: lossy UTF-8 conversion can conflate distinct files.
        return Set(result.standardOutput.split(separator: 0).map { Data($0) })
    }

    private func run(_ arguments: [String], in path: String) async throws -> GitInvocationResult {
        try Task.checkCancellation()
        return try await git.run(arguments, in: path)
    }
}
