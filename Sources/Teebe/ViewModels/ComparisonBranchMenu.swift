import Foundation
import TeebeCore

/// Which refs the Comparison Branch submenu offers. A real repository has dozens of
/// branches and work is only ever compared against a handful of them, so the menu
/// lists those and sends everything else through "Other…".
enum ComparisonBranchMenu {
    /// The names that mean "the line work merges into".
    private static let integrationNames: Set<String> = [
        "main", "master", "dev", "develop", "development", "trunk", "staging", "production", "prod"
    ]
    /// Release lines are integration branches too, and there is no fixed set of them.
    private static let integrationPrefixes = ["release/", "releases/"]
    /// Read first, alphabetical after: the branches a repository actually merges into
    /// should not sit below a year of `release/…` tags.
    private static let leadingNames = ["main", "master", "dev", "develop"]

    /// The name without its remote: `origin/main` and `main` are both `main`.
    static func shortName(_ branch: CleanupBranch) -> String {
        guard branch.ref.hasPrefix("refs/remotes/") else { return branch.name }
        return branch.name.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch.name
    }

    /// The remote a ref belongs to, or nil for a local branch.
    static func remote(_ branch: CleanupBranch) -> String? {
        guard branch.ref.hasPrefix("refs/remotes/") else { return nil }
        return branch.name.split(separator: "/", maxSplits: 1).first.map(String.init)
    }

    static func isIntegrationName(_ short: String) -> Bool {
        integrationNames.contains(short) || integrationPrefixes.contains { short.hasPrefix($0) }
    }

    /// The branches the submenu shows, in display order. Only local refs and `origin/`
    /// ones: origin is the remote the background fetch keeps current, so where both
    /// `x` and `origin/x` exist only `origin/x` is offered. A repository with no
    /// remote keeps its local branches. The saved choice is always in the list,
    /// filter or no filter, so it stays visible and can be changed.
    static func entries(_ branches: [CleanupBranch], saved: String? = nil) -> [CleanupBranch] {
        let freshRemoteNames = Set(branches.filter { remote($0) == "origin" }.map(shortName))
        let kept = branches.filter { branch in
            if branch.ref == saved { return true }
            let remote = remote(branch)
            guard remote == nil || remote == "origin" else { return false }
            guard isIntegrationName(shortName(branch)) else { return false }
            return remote != nil || !freshRemoteNames.contains(shortName(branch))
        }
        return kept.sorted { first, second in
            let (a, b) = (rank(first), rank(second))
            guard a == b else { return a < b }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// Resolve a hand-typed ref against everything the repository has, not just the
    /// filtered menu. A bare name also matches its `origin/` form: typing `dev` in a
    /// repo that only tracks `origin/dev` means that branch.
    static func resolve(_ typed: String, in branches: [CleanupBranch]) -> CleanupBranch? {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return branches.first { $0.name == name || $0.ref == name }
            ?? branches.first { $0.name == "origin/" + name }
    }

    private static func rank(_ branch: CleanupBranch) -> Int {
        leadingNames.firstIndex(of: shortName(branch)) ?? leadingNames.count
    }
}
