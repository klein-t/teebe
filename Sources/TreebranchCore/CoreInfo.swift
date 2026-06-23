import Foundation

/// Top-level namespace + invariants for the Treebranch core library.
///
/// Intentionally tiny: it exists from M0 to prove the red→green→refactor loop and
/// the CI pipeline before any real logic lands.
public enum TreebranchCore {
    /// Library version (kept in sync with releases).
    public static let version = "0.1.0"

    /// Default base-branch candidates, in priority order, used when a repo has no
    /// explicitly configured base branch (TECH_SPEC §3: "default detect `main`
    /// then `master`").
    public static let defaultBaseBranchCandidates = ["main", "master"]

    /// Resolve the base branch for a repo: the configured value if present,
    /// otherwise the first default candidate that exists in `availableBranches`.
    /// Returns `nil` if nothing matches (caller surfaces a "missing base" state).
    public static func resolveBaseBranch(
        configured: String?,
        availableBranches: [String]
    ) -> String? {
        if let configured, availableBranches.contains(configured) {
            return configured
        }
        return defaultBaseBranchCandidates.first { availableBranches.contains($0) }
    }
}
