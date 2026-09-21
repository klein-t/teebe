import Foundation
import Observation
import TeebeCore

/// Form state for the New Worktree sheet: the branch to create (or check out),
/// where it starts from, and the folder it lands in. All the rules live here as
/// pure functions so the sheet stays a thin view.
@MainActor
@Observable
final class NewWorktreeModel {
    let repo: Repository
    /// Start-point choices: the repo's local branches plus origin's.
    let startPoints: [String]

    var branch = "" {
        didSet { branchDidChange(from: oldValue) }
    }
    var startPoint: String
    /// Where the worktree folder goes. Follows the branch name until the user
    /// picks a folder by hand.
    private(set) var location = ""
    /// Check out the matching existing branch instead of creating a new one.
    var useExistingBranch = false
    var isCreating = false
    /// The failure from the last Create attempt, shown inline in the sheet.
    var errorMessage: String?

    /// True once "Choose…" was used: the location stops tracking the branch name.
    private var hasCustomLocation = false
    /// Injected so the folder check is testable without touching the disk.
    private let folderExists: @Sendable (String) -> Bool
    /// Every local + remote branch, for the "already exists" check.
    private let allBranches: [Branch]

    init(
        repo: Repository,
        branches: [Branch],
        comparisonBranch: String?,
        primaryBranch: String?,
        folderExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.repo = repo
        self.allBranches = branches
        self.folderExists = folderExists
        self.startPoints = Self.startPointOptions(branches)
        self.startPoint = Self.defaultStartPoint(
            comparison: comparisonBranch, primaryBranch: primaryBranch, options: startPoints)
    }

    // MARK: - Derived state

    var trimmedBranch: String { branch.trimmingCharacters(in: .whitespaces) }

    /// The existing local or origin branch the typed name collides with, if any.
    var existingBranch: String? {
        Self.existingBranch(named: trimmedBranch, in: allBranches)
    }

    /// What's wrong with the branch name, or nil when it's usable.
    var branchProblem: String? {
        guard !trimmedBranch.isEmpty else { return nil }
        guard !branch.contains(" ") else { return "Branch names can't contain spaces." }
        guard Self.isValidRefName(trimmedBranch) else { return "Not a valid branch name." }
        if let existing = existingBranch, !useExistingBranch {
            return "A branch named \(existing) already exists."
        }
        return nil
    }

    var locationProblem: String? {
        guard !location.isEmpty else { return nil }
        return folderExists(location) ? "Folder already exists." : nil
    }

    var canCreate: Bool {
        !isCreating && !trimmedBranch.isEmpty && !location.isEmpty
            && branchProblem == nil && locationProblem == nil
    }

    /// Start point only applies when a branch is being created.
    var isCreatingBranch: Bool { !(useExistingBranch && existingBranch != nil) }

    /// The start point to pass to git: nil when checking out an existing branch.
    var resolvedStartPoint: String? {
        guard isCreatingBranch, !startPoint.isEmpty else { return nil }
        return startPoint
    }

    func setLocation(_ path: String, custom: Bool = true) {
        location = path
        hasCustomLocation = custom
    }

    private func branchDidChange(from oldValue: String) {
        guard branch != oldValue else { return }
        if existingBranch == nil { useExistingBranch = false }
        guard !hasCustomLocation else { return }
        location = Self.defaultLocation(repoPath: repo.path, branch: trimmedBranch)
    }

    // MARK: - Pure rules

    /// Local branches plus origin's, in that order. Other remotes are left out:
    /// origin is the one teebe keeps fetched.
    static func startPointOptions(_ branches: [Branch]) -> [String] {
        let local = branches.filter { !$0.isRemote }.map(\.name)
        let origin = branches.filter { $0.isRemote && $0.name.hasPrefix("origin/") }
            .map(\.name)
            .filter { !$0.hasSuffix("/HEAD") }
        return local + origin
    }

    /// The repo's comparison branch when it's offered, else the primary checkout's
    /// branch, else whatever is first.
    static func defaultStartPoint(comparison: String?, primaryBranch: String?, options: [String]) -> String {
        if let comparison, options.contains(comparison) { return comparison }
        if let primaryBranch, options.contains(primaryBranch) { return primaryBranch }
        return options.first ?? ""
    }

    /// A sibling of the primary checkout, named `<repo folder>-<branch>` with the
    /// branch's slashes flattened (a folder per path component would nest).
    static func defaultLocation(repoPath: String, branch: String) -> String {
        guard !branch.isEmpty else { return "" }
        let repoFolder = (repoPath as NSString).lastPathComponent
        let parent = (repoPath as NSString).deletingLastPathComponent
        let suffix = branch.replacingOccurrences(of: "/", with: "-")
        return (parent as NSString).appendingPathComponent("\(repoFolder)-\(suffix)")
    }

    /// The local or origin branch `name` already refers to, if any: `feat/x` matches
    /// both `feat/x` and `origin/feat/x`.
    static func existingBranch(named name: String, in branches: [Branch]) -> String? {
        guard !name.isEmpty else { return nil }
        if let local = branches.first(where: { !$0.isRemote && $0.name == name }) { return local.name }
        return branches.first { $0.isRemote && $0.name == "origin/" + name }?.name
    }

    /// `git check-ref-format --branch` semantics, the parts that matter for a
    /// branch name typed by hand.
    static func isValidRefName(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@" else { return false }
        guard !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"), !name.hasSuffix(".") else { return false }
        guard !name.contains(".."), !name.contains("@{"), !name.contains("//") else { return false }
        let forbidden = Set(" ~^:?*[\\")
        guard !name.contains(where: { forbidden.contains($0) }) else { return false }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        for component in name.split(separator: "/", omittingEmptySubsequences: false) {
            if component.isEmpty || component.hasPrefix(".") || component.hasSuffix(".lock") { return false }
        }
        return true
    }
}
