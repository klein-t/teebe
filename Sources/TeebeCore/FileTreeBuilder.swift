import Foundation

/// Builds `FileNode` trees from the filesystem, lazily (one directory level per
/// call) so large repos stay responsive (TECH_SPEC §4). Honors a "show ignored"
/// toggle via a supplied ignored-path set.
public struct FileTreeBuilder: Sendable {
    public struct Options: Sendable {
        /// Show dotfiles (`.gitignore`, `.github`, …). `.git` is always hidden.
        public var showHidden: Bool
        /// Show files git ignores.
        public var showIgnored: Bool
        /// Repo-relative paths git ignores (from `git status --ignored` /
        /// `git check-ignore`). Entries may or may not have a trailing slash.
        public var ignoredPaths: Set<String>

        public init(showHidden: Bool = true, showIgnored: Bool = false, ignoredPaths: Set<String> = []) {
            self.showHidden = showHidden
            self.showIgnored = showIgnored
            self.ignoredPaths = ignoredPaths
        }
    }

    public let rootPath: String
    public var options: Options

    public init(rootPath: String, options: Options = Options()) {
        // Standardize so enumerated child paths (which the filesystem resolves,
        // e.g. /var → /private/var) share this exact prefix.
        self.rootPath = PathUtil.standardized(rootPath)
        self.options = options
    }

    /// The root node with its immediate children loaded one level deep.
    public func buildRoot() throws -> FileNode {
        let children = try loadChildren(of: rootPath)
        return FileNode(
            path: rootPath,
            name: (rootPath as NSString).lastPathComponent,
            isDirectory: true,
            children: children
        )
    }

    /// Immediate children of `directoryPath`. Directories come back with
    /// `children == nil` (unloaded) for lazy expansion.
    public func loadChildren(of directoryPath: String) throws -> [FileNode] {
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: directoryPath)
        let entries = try fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: []
        )

        var nodes: [FileNode] = []
        for url in entries {
            let name = url.lastPathComponent
            if name == ".git" { continue }
            if !options.showHidden && name.hasPrefix(".") { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            let relative = relativePath(of: url.path)
            if !options.showIgnored && isIgnored(relative) { continue }

            nodes.append(
                FileNode(
                    path: url.path,
                    name: name,
                    isDirectory: isDirectory,
                    children: nil,
                    modifiedAt: values?.contentModificationDate
                )
            )
        }
        return Self.sorted(nodes)
    }

    /// Search every directory without expanding the visible tree. Run off the UI
    /// thread; cancellation is checked between entries. Never follow directory
    /// symlinks or descend into Git metadata or excluded ignored directories.
    public func search(_ query: String) throws -> [FileNode] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let entries = FileManager.default.enumerator(at: URL(fileURLWithPath: rootPath),
                includingPropertiesForKeys: keys, errorHandler: { _, _ in true }) else { return [] }
        var matches: [FileNode] = []
        for case let url as URL in entries {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: Set(keys))
            let directory = values?.isDirectory == true
            let relative = relativePath(of: url.path)
            if url.lastPathComponent == ".git"
                || (!options.showHidden && url.lastPathComponent.hasPrefix("."))
                || (!options.showIgnored && isIgnored(relative)) {
                if directory { entries.skipDescendants() }
                continue
            }
            if directory {
                if values?.isSymbolicLink == true { entries.skipDescendants() }
                continue
            }
            guard relative.localizedCaseInsensitiveContains(query) else { continue }
            matches.append(FileNode(path: url.path, isDirectory: false, modifiedAt: values?.contentModificationDate))
        }
        return matches.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Directories first, then files; case-insensitive name order (Finder-like).
    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func isIgnored(_ relative: String) -> Bool {
        options.ignoredPaths.contains(relative) || options.ignoredPaths.contains(relative + "/")
    }

    /// Path of `absolute` relative to `rootPath` (forward slashes, no leading slash).
    func relativePath(of absolute: String) -> String {
        PathUtil.relativePath(of: absolute, under: rootPath)
    }
}

/// Path helpers shared by the tree builder, the status overlay, and the app.
public enum PathUtil {
    /// Resolve symlinks to the canonical real path so two references to the same
    /// location compare equal. Uses POSIX `realpath`, which (unlike
    /// `resolvingSymlinksInPath`) matches the form `FileManager` enumeration and
    /// `git worktree list` return for macOS firmlinks (`/var` → `/private/var`).
    /// Falls back to the input for paths that do not exist.
    public static func standardized(_ path: String) -> String {
        path.withCString { cString in
            guard let resolved = realpath(cString, nil) else { return path }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    /// `absolute` relative to `root` (no leading slash); empty when equal.
    public static func relativePath(of absolute: String, under root: String) -> String {
        var prefix = root
        if !prefix.hasSuffix("/") { prefix += "/" }
        if absolute.hasPrefix(prefix) { return String(absolute.dropFirst(prefix.count)) }
        if absolute == root { return "" }
        return absolute
    }
}

/// Overlays git change status onto a `FileNode` tree by repo-relative path. Files
/// get their `change`; directories get `containsChanges` if any descendant changed
/// (works even for collapsed/unloaded directories, since it consults the change
/// list directly).
public enum StatusOverlay {
    public static func apply(_ changes: [FileChange], to root: FileNode, rootPath: String) -> FileNode {
        let byPath = Dictionary(changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let changedPaths = Set(changes.map(\.path))
        return overlay(root, rootPath: PathUtil.standardized(rootPath), byPath: byPath, changedPaths: changedPaths)
    }

    private static func overlay(
        _ node: FileNode,
        rootPath: String,
        byPath: [String: FileChange],
        changedPaths: Set<String>
    ) -> FileNode {
        var node = node
        let relative = PathUtil.relativePath(of: node.path, under: rootPath)

        if node.isDirectory {
            let prefix = relative.isEmpty ? "" : relative + "/"
            node.containsChanges = changedPaths.contains { prefix.isEmpty ? true : $0.hasPrefix(prefix) }
                && !changedPaths.isEmpty
            if let children = node.children {
                node.children = children.map { overlay($0, rootPath: rootPath, byPath: byPath, changedPaths: changedPaths) }
            }
        } else {
            node.change = byPath[relative]
        }
        return node
    }
}
