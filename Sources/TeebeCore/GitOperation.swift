import Foundation

/// A Git operation left unfinished in a checkout. Its state lives in the
/// checkout's own git directory, so removing the worktree would throw away what
/// is needed to continue or abort it.
public enum GitOperation: Equatable, Sendable {
    case rebase, applyingPatches, merge, cherryPick, revert, bisect

    /// The operation in progress in the git directory at `gitDirectory`, if any.
    public static func detect(gitDirectory: String) -> GitOperation? {
        let base = URL(fileURLWithPath: gitDirectory)
        return detect(
            exists: { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) },
            sequencerTodo: { try? String(contentsOf: base.appendingPathComponent("sequencer/todo"), encoding: .utf8) })
    }

    /// `exists` answers for paths relative to the git directory. A rebase is
    /// checked first: a bisect or a merge can be what it stopped in the middle of.
    static func detect(exists: (String) -> Bool, sequencerTodo: () -> String?) -> GitOperation? {
        if exists("rebase-merge") { return .rebase }
        if exists("rebase-apply") { return exists("rebase-apply/applying") ? .applyingPatches : .rebase }
        if exists("MERGE_HEAD") { return .merge }
        if exists("CHERRY_PICK_HEAD") { return .cherryPick }
        if exists("REVERT_HEAD") { return .revert }
        // A multi-commit cherry-pick or revert between two of its commits.
        if exists("sequencer") { return sequencerTodo()?.hasPrefix("revert") == true ? .revert : .cherryPick }
        if exists("BISECT_LOG") { return .bisect }
        return nil
    }
}
