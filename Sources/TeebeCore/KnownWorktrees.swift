import Foundation

/// Worktrees across all added repositories, shared by the agent readers.
public final class KnownWorktrees: @unchecked Sendable {
    private let lock = NSLock()
    private var pathsByRepository: [String: Set<String>] = [:]
    private var storedPaths: [String] = []

    public init() {}

    public var paths: [String] { lock.withLock { storedPaths } }

    public func paths(forRepository repository: String) -> [String] {
        lock.withLock { (pathsByRepository[repository] ?? []).sorted() }
    }

    /// Order and duplicate paths do not change the set.
    @discardableResult
    public func update(_ paths: [String], forRepository repository: String) -> Bool {
        let next = Set(paths)
        return lock.withLock {
            guard next != (pathsByRepository[repository] ?? []) else { return false }
            pathsByRepository[repository] = next
            storedPaths = Set(pathsByRepository.values.flatMap { $0 }).sorted()
            return true
        }
    }

    /// Forget removed repositories without discarding other repositories' lists.
    public func retainRepositories(_ repositories: [String]) {
        let retained = Set(repositories)
        lock.withLock {
            pathsByRepository = pathsByRepository.filter { retained.contains($0.key) }
            storedPaths = Set(pathsByRepository.values.flatMap { $0 }).sorted()
        }
    }
}
