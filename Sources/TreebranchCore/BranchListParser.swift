import Foundation

/// Parses the output of:
/// `git for-each-ref --format=%(refname)%00%(objectname)%00%(upstream:short)%00%(HEAD) refs/heads refs/remotes`
///
/// Each line has four NUL-separated fields: full refname, commit SHA, upstream
/// short name (possibly empty), and the HEAD marker (`*` for the current branch).
public enum BranchListParser {
    static let fieldSeparator = "\u{0}"

    /// The `--format` string ProcessGitClient pairs with this parser.
    public static let format = "%(refname)%00%(objectname)%00%(upstream:short)%00%(HEAD)"

    public static func parse(_ output: String) -> [Branch] {
        var branches: [Branch] = []
        for rawLine in output.split(whereSeparator: { $0 == "\n" }) {
            let line = String(rawLine)
            if line.isEmpty { continue }
            let fields = line.components(separatedBy: fieldSeparator)
            guard let refname = fields.first, !refname.isEmpty else { continue }

            let sha = fields.count > 1 ? fields[1] : ""
            let upstream = fields.count > 2 ? fields[2] : ""
            let headMarker = fields.count > 3 ? fields[3] : ""

            let isRemote = refname.hasPrefix("refs/remotes/")
            let shortName: String
            if isRemote {
                shortName = String(refname.dropFirst("refs/remotes/".count))
            } else if refname.hasPrefix("refs/heads/") {
                shortName = String(refname.dropFirst("refs/heads/".count))
            } else {
                shortName = refname
            }

            // Skip the symbolic `origin/HEAD` pointer.
            if isRemote && shortName.hasSuffix("/HEAD") { continue }

            branches.append(
                Branch(
                    name: shortName,
                    isCurrent: headMarker == "*",
                    isRemote: isRemote,
                    upstream: upstream.isEmpty ? nil : upstream,
                    targetSHA: sha.isEmpty ? nil : sha
                )
            )
        }
        return branches
    }
}
