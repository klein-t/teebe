import Foundation

/// The gitignored files a worktree removal would delete for good: Git doesn't
/// have them, so it can't restore them. Git lists an ignored folder as one entry;
/// this counts and names the files inside, up to `limit`, so the confirmation
/// can say how many, and removal can tell when one was added since.
public struct IgnoredFiles: Equatable, Sendable {
    /// Every file found, relative to the worktree, sorted; at most `limit` of them.
    public let paths: [String]
    /// There are more files than `limit`: `paths` is not all of them.
    public let isTruncated: Bool

    /// Enough to say "10,000+" and to notice a new file, without walking a huge
    /// dependency folder on every check.
    public static let limit = 10_000

    public init(paths: [String], isTruncated: Bool) {
        self.paths = paths
        self.isTruncated = isTruncated
    }

    /// The files under `root` that the ignored `entries` (as `git status` lists
    /// them, a folder ending in "/") hold. Symbolic links count as files and are
    /// never followed.
    public static func inventory(in root: String, entries: [String], limit: Int = limit) -> IgnoredFiles {
        var paths: [String] = []
        let base = URL(fileURLWithPath: root)
        for entry in entries.sorted() {
            guard paths.count < limit else { return IgnoredFiles(paths: paths.sorted(), isTruncated: true) }
            guard entry.hasSuffix("/") else { paths.append(entry); continue }
            guard let walker = FileManager.default.enumerator(atPath: base.appendingPathComponent(entry).path) else { continue }
            while let relative = walker.nextObject() as? String {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { continue }
                guard paths.count < limit else { return IgnoredFiles(paths: paths.sorted(), isTruncated: true) }
                paths.append(entry + relative)
            }
        }
        return IgnoredFiles(paths: paths.sorted(), isTruncated: false)
    }

    /// The folders inside the ignored `entries` that are Git repositories of their
    /// own (they hold a `.git` folder or file), relative to `root`, sorted. A
    /// repository's `.git` is not walked, and symbolic links are never followed.
    public static func repositories(in root: String, entries: [String]) -> [String] {
        var found: [String] = []
        let base = URL(fileURLWithPath: root)
        for entry in entries where entry.hasSuffix("/") {
            guard let walker = FileManager.default.enumerator(atPath: base.appendingPathComponent(entry).path) else { continue }
            while let relative = walker.nextObject() as? String {
                guard (relative as NSString).lastPathComponent == ".git" else { continue }
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory { walker.skipDescendants() }
                let folder = (relative as NSString).deletingLastPathComponent
                found.append(entry + (folder.isEmpty ? "" : folder + "/"))
            }
        }
        return found.sorted()
    }

    /// Files that look hard to get back: secrets, keys and certificates, local
    /// settings. Only a way to choose which names to show first; nothing about the
    /// others is assumed.
    public static func looksIrreplaceable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") || name.hasSuffix(".env") { return true }
        if [".pem", ".key", ".p12", ".pfx"].contains(where: name.hasSuffix) { return true }
        if name.hasPrefix("id_") { return true }
        return name.hasSuffix(".local") || name.contains(".local.")
    }

    /// The files that look hard to get back, in path order.
    public var irreplaceable: [String] { paths.filter(Self.looksIrreplaceable) }
}
