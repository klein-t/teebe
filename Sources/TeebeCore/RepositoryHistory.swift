import Foundation

public enum RepositoryHistory {
    /// Keep the most recent occurrence of each canonical folder.
    public static func unique(_ paths: [String]) -> [Repository] {
        var seen = Set<String>()
        return paths.reversed().compactMap { path -> Repository? in
            let expanded = (path as NSString).expandingTildeInPath
            let canonical = PathUtil.standardized((expanded as NSString).standardizingPath)
            return seen.insert(canonical).inserted ? Repository(path: canonical) : nil
        }.reversed()
    }

    public static func title(for repo: Repository, among repositories: [Repository]) -> String {
        guard repositories.contains(where: { $0.path != repo.path && $0.name == repo.name }) else { return repo.name }
        return "\(repo.name) (\((repo.path as NSString).deletingLastPathComponent))"
    }
}
