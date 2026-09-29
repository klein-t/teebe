import Foundation

/// Nil fields inherit the global default. An explicit empty comparison ref means
/// no extra branch for this project, even when the global default names one.
public struct ProjectPreferences: Codable, Equatable, Sendable {
    public var groupByStatus: Bool?
    public var fetchAutomatically: Bool?
    public var worktreeSort: String?
    public var fileSort: String?
    public var changedOnly: Bool?
    public var showIgnored: Bool?
    public var comparisonRef: String?
    public var worktreeParent: String?

    public init(groupByStatus: Bool? = nil, fetchAutomatically: Bool? = nil,
                worktreeSort: String? = nil, fileSort: String? = nil,
                changedOnly: Bool? = nil, showIgnored: Bool? = nil,
                comparisonRef: String? = nil, worktreeParent: String? = nil) {
        self.groupByStatus = groupByStatus
        self.fetchAutomatically = fetchAutomatically
        self.worktreeSort = worktreeSort
        self.fileSort = fileSort
        self.changedOnly = changedOnly
        self.showIgnored = showIgnored
        self.comparisonRef = comparisonRef
        self.worktreeParent = worktreeParent
    }

    public func inheriting(_ defaults: Self) -> Self {
        Self(groupByStatus: groupByStatus ?? defaults.groupByStatus,
             fetchAutomatically: fetchAutomatically ?? defaults.fetchAutomatically,
             worktreeSort: worktreeSort ?? defaults.worktreeSort,
             fileSort: fileSort ?? defaults.fileSort,
             changedOnly: changedOnly ?? defaults.changedOnly,
             showIgnored: showIgnored ?? defaults.showIgnored,
             comparisonRef: comparisonRef ?? defaults.comparisonRef,
             worktreeParent: worktreeParent ?? defaults.worktreeParent)
    }
}
