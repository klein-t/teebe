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

    private static func rank(_ branch: CleanupBranch) -> Int {
        leadingNames.firstIndex(of: shortName(branch)) ?? leadingNames.count
    }
}

/// One line of the Comparison Branch picker: a branch, or the Automatic choice.
struct ComparisonBranchRow: Identifiable, Equatable {
    /// The ref this row saves. Empty means Automatic, which saves no override.
    let id: String
    /// Left-hand text: the branch name without its remote, or "Automatic".
    let name: String
    /// Right-hand text: where the branch lives, or what Automatic resolved to.
    let detail: String
    /// False for an Automatic row that resolved to nothing: there is nothing to pick.
    let isEnabled: Bool
}

/// The picker's two lists. Suggested is the handful anyone actually means; the
/// rest is every other ref, so no branch is unreachable.
struct ComparisonBranchSections: Equatable {
    var suggested: [ComparisonBranchRow] = []
    var all: [ComparisonBranchRow] = []
    var isEmpty: Bool { suggested.isEmpty && all.isEmpty }
}

extension ComparisonBranchMenu {
    /// Everything the picker shows, already ordered and filtered. Search is a
    /// case-insensitive substring of the full ref name, so both `dev` and
    /// `origin/dev` find `origin/dev`.
    static func sections(_ branches: [CleanupBranch], automatic: CleanupBranch?,
                         search: String = "") -> ComparisonBranchSections {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ text: String) -> Bool {
            query.isEmpty || text.lowercased().contains(query)
        }

        var sections = ComparisonBranchSections()
        let automaticName = automatic?.name
        if matches("automatic " + (automaticName ?? "unavailable")) {
            sections.suggested.append(ComparisonBranchRow(
                id: "", name: "Automatic", detail: automaticName ?? "unavailable",
                isEnabled: automatic != nil))
        }

        // origin's copy first, then the local branches origin has no copy of.
        var suggestedRefs: Set<String> = []
        let originSuggested = leadingNames.compactMap { short in
            branches.first { $0.ref == "refs/remotes/origin/" + short }
        }
        let localSuggested = leadingNames.compactMap { short -> CleanupBranch? in
            guard !originSuggested.contains(where: { shortName($0) == short }) else { return nil }
            return branches.first { $0.ref == "refs/heads/" + short }
        }
        for branch in originSuggested + localSuggested {
            suggestedRefs.insert(branch.ref)
            if matches(branch.name) { sections.suggested.append(row(branch)) }
        }

        sections.all = branches
            .filter { !suggestedRefs.contains($0.ref) && matches($0.name) }
            .sorted { first, second in
                let (a, b) = (shortName(first), shortName(second))
                guard a.localizedStandardCompare(b) == .orderedSame else {
                    return a.localizedStandardCompare(b) == .orderedAscending
                }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            .map(row)
        return sections
    }

    private static func row(_ branch: CleanupBranch) -> ComparisonBranchRow {
        ComparisonBranchRow(id: branch.ref, name: shortName(branch),
                            detail: remote(branch) ?? "local", isEnabled: true)
    }
}
