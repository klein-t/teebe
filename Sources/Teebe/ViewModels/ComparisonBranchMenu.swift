import Foundation
import TeebeCore

/// How the extra-merge-target picker orders a repository's branches. Merges are
/// already checked against the default branch and the usual integration branches;
/// the picker adds one more, so it suggests the handful anyone actually means and
/// lists every other ref below.
enum ComparisonBranchMenu {
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
}

/// One line of the extra-branch picker: a branch, or None.
struct ComparisonBranchRow: Identifiable, Equatable {
    /// The ref this row saves. Empty means None: no extra branch.
    let id: String
    /// Left-hand text: the branch name without its remote, or "None".
    let name: String
    /// Right-hand text: where the branch lives, or "No extra branch".
    let detail: String
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
    static func sections(_ branches: [CleanupBranch], search: String = "") -> ComparisonBranchSections {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ text: String) -> Bool {
            query.isEmpty || text.lowercased().contains(query)
        }

        var sections = ComparisonBranchSections()
        if matches("none no extra branch") {
            sections.suggested.append(ComparisonBranchRow(id: "", name: "None", detail: "No extra branch"))
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
                            detail: remote(branch) ?? "local")
    }
}
