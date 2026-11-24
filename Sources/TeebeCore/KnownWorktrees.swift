import Foundation

/// Worktrees across all added repositories, shared by the agent readers.
public final class KnownWorktrees: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPaths: Set<String> = []

    public init() {}

    public var paths: [String] { lock.withLock { storedPaths.sorted() } }

    /// Order and duplicate paths do not change the set.
    @discardableResult
    public func update(_ paths: [String]) -> Bool {
        let next = Set(paths)
        return lock.withLock {
            guard next != storedPaths else { return false }
            storedPaths = next
            return true
        }
    }
}
