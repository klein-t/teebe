import Foundation

public extension FileTreeBuilder {
    /// Build a nested `FileNode` tree from a flat list of repo-relative paths
    /// (used by branch-snapshot browse and the `Changed` filter, where the tree is
    /// derived from git rather than the live filesystem). Intermediate directories
    /// are synthesized; node paths are prefixed with the standardized `rootPath`.
    static func tree(fromRelativePaths paths: [String], rootPath: String) -> FileNode {
        let root = PathUtil.standardized(rootPath)

        final class Node {
            var children: [String: Node] = [:]
            var isFile = false
        }
        let builderRoot = Node()
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var cursor = builderRoot
            for (index, part) in parts.enumerated() {
                let next = cursor.children[part] ?? {
                    let node = Node()
                    cursor.children[part] = node
                    return node
                }()
                cursor = next
                if index == parts.count - 1 { cursor.isFile = true }
            }
        }

        func convert(_ node: Node, path: String, name: String) -> FileNode {
            if node.children.isEmpty {
                return FileNode(path: path, name: name, isDirectory: !node.isFile, children: node.isFile ? nil : [])
            }
            let kids = node.children.map { key, value in
                convert(value, path: path + "/" + key, name: key)
            }
            return FileNode(path: path, name: name, isDirectory: true, children: FileTreeBuilder.sorted(kids))
        }

        return convert(builderRoot, path: root, name: (root as NSString).lastPathComponent)
    }
}
