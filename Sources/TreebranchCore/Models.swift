import Foundation

// MARK: - Repository

/// A git repository the user has added. Its `path` is the main worktree root.
public struct Repository: Identifiable, Hashable, Sendable {
    /// Absolute path to the repository's main working directory (the primary checkout).
    public var path: String
    /// Display name (defaults to the last path component).
    public var name: String
    /// Configured base branch (`nil` = auto-detect `main` then `master`).
    public var baseBranch: String?

    public var id: String { path }

    public init(path: String, name: String? = nil, baseBranch: String? = nil) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.baseBranch = baseBranch
    }
}

// MARK: - Worktree

/// A checked-out working directory of a repo (primary checkout or a linked
/// `git worktree add` directory). Bound 1:1 to a branch (unless detached/bare).
public struct Worktree: Identifiable, Hashable, Sendable {
    /// Absolute path to the worktree directory.
    public var path: String
    /// Short branch name (e.g. `main`); `nil` when detached or bare.
    public var branch: String?
    /// Commit SHA at HEAD (empty for a bare worktree).
    public var head: String
    /// `true` for the repository's primary checkout (first entry of `worktree list`).
    public var isPrimary: Bool
    public var isBare: Bool
    public var isDetached: Bool
    public var isLocked: Bool

    public var id: String { path }

    /// Display name: the worktree directory's last path component.
    public var name: String { (path as NSString).lastPathComponent }

    public init(
        path: String,
        branch: String? = nil,
        head: String = "",
        isPrimary: Bool = false,
        isBare: Bool = false,
        isDetached: Bool = false,
        isLocked: Bool = false
    ) {
        self.path = path
        self.branch = branch
        self.head = head
        self.isPrimary = isPrimary
        self.isBare = isBare
        self.isDetached = isDetached
        self.isLocked = isLocked
    }
}

// MARK: - Branch

/// A named pointer to commits. For browsing, any branch's committed tree can be
/// viewed read-only without checkout (D2).
public struct Branch: Identifiable, Hashable, Sendable {
    /// Short branch name (e.g. `main`, or `origin/feature` for a remote).
    public var name: String
    /// `true` if this is the worktree's current branch.
    public var isCurrent: Bool
    /// `true` for remote-tracking branches (`refs/remotes/...`).
    public var isRemote: Bool
    /// Upstream short name, if any (e.g. `origin/main`).
    public var upstream: String?
    /// Commit SHA the branch points at.
    public var targetSHA: String?

    public var id: String { (isRemote ? "remotes/" : "heads/") + name }

    public init(
        name: String,
        isCurrent: Bool = false,
        isRemote: Bool = false,
        upstream: String? = nil,
        targetSHA: String? = nil
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.isRemote = isRemote
        self.upstream = upstream
        self.targetSHA = targetSHA
    }
}

// MARK: - Change status

/// The git status of one side (staged or unstaged) of a path.
///
/// Maps from `git status --porcelain=v2` XY codes and `--name-status` letters.
public enum ChangeStatus: String, Equatable, Hashable, Sendable, CaseIterable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case conflicted
    case untracked
    case ignored
    case typeChanged

    /// Parse a single porcelain/name-status letter (`M`, `A`, `D`, `R`, `C`, `U`,
    /// `T`, `?`, `!`, `.`/space). Returns `nil` for unknown codes.
    public init?(porcelainCode code: Character) {
        switch code {
        case ".", " ": self = .unmodified
        case "M": self = .modified
        case "A": self = .added
        case "D": self = .deleted
        case "R": self = .renamed
        case "C": self = .copied
        case "U": self = .conflicted
        case "T": self = .typeChanged
        case "?": self = .untracked
        case "!": self = .ignored
        default: return nil
        }
    }

    /// One-letter badge for the UI (`nil` when nothing to show).
    public var badgeLetter: String? {
        switch self {
        case .unmodified, .ignored: return nil
        case .modified, .typeChanged: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .conflicted: return "U"
        case .untracked: return "?"
        }
    }
}

/// A single changed path, carrying both the staged (index) and unstaged (worktree)
/// sides, plus the source path for renames/copies.
public struct FileChange: Identifiable, Hashable, Sendable {
    /// Repo/worktree-relative path, forward slashes.
    public var path: String
    /// Source path for a rename or copy (the "from" side); otherwise `nil`.
    public var originalPath: String?
    /// Staged side (porcelain X).
    public var indexStatus: ChangeStatus
    /// Unstaged side (porcelain Y).
    public var worktreeStatus: ChangeStatus

    public var id: String { path }

    /// Anything staged (and not merely untracked/ignored).
    public var isStaged: Bool {
        switch indexStatus {
        case .unmodified, .untracked, .ignored: return false
        default: return true
        }
    }

    public var isUntracked: Bool { worktreeStatus == .untracked || indexStatus == .untracked }
    public var isConflicted: Bool { indexStatus == .conflicted || worktreeStatus == .conflicted }

    /// The single status used to badge a row: prefer an unstaged change, else the
    /// staged one.
    public var primaryStatus: ChangeStatus {
        worktreeStatus != .unmodified ? worktreeStatus : indexStatus
    }

    public init(
        path: String,
        originalPath: String? = nil,
        indexStatus: ChangeStatus = .unmodified,
        worktreeStatus: ChangeStatus = .unmodified
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
    }
}

// MARK: - File tree

/// A node in the file tree. Children are loaded lazily: `nil` means "not yet
/// loaded" (a collapsed/unexpanded directory); `[]` means "loaded, empty".
public struct FileNode: Identifiable, Hashable, Sendable {
    /// Absolute filesystem path; stable identity.
    public var path: String
    public var name: String
    public var isDirectory: Bool
    /// `nil` until the directory is expanded/loaded.
    public var children: [FileNode]?
    /// Git change for a file at this exact path (`nil` = clean / not applicable).
    public var change: FileChange?
    /// For directories: whether any descendant has a git change (folder dot).
    public var containsChanges: Bool
    /// Filesystem modification time, when known (drives "recently changed" sort).
    public var modifiedAt: Date?

    public var id: String { path }

    public init(
        path: String,
        name: String? = nil,
        isDirectory: Bool,
        children: [FileNode]? = nil,
        change: FileChange? = nil,
        containsChanges: Bool = false,
        modifiedAt: Date? = nil
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.isDirectory = isDirectory
        self.children = children
        self.change = change
        self.containsChanges = containsChanges
        self.modifiedAt = modifiedAt
    }
}

// MARK: - Diff model

public enum DiffLineKind: String, Equatable, Hashable, Sendable {
    case context
    case addition
    case deletion
}

/// A single line within a diff hunk. Line numbers are `nil` on the side where the
/// line does not exist (additions have no old number; deletions have no new number).
public struct DiffLine: Hashable, Sendable {
    public var kind: DiffLineKind
    /// Line text without the leading `+`/`-`/space marker.
    public var content: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(kind: DiffLineKind, content: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.kind = kind
        self.content = content
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// A unified-diff hunk (`@@ -oldStart,oldCount +newStart,newCount @@ header`).
public struct DiffHunk: Hashable, Sendable {
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    /// Optional trailing section context after the ranges on the `@@` line.
    public var header: String
    public var lines: [DiffLine]

    public init(oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, header: String = "", lines: [DiffLine] = []) {
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.header = header
        self.lines = lines
    }
}

public enum DiffFileStatus: String, Equatable, Hashable, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case unknown
}

/// One file's worth of a unified diff. Binary files carry `isBinary == true` and no
/// hunks; renames carry distinct `oldPath`/`newPath`.
public struct DiffFile: Identifiable, Hashable, Sendable {
    public var oldPath: String?
    public var newPath: String?
    public var status: DiffFileStatus
    public var isBinary: Bool
    public var hunks: [DiffHunk]

    public var id: String { newPath ?? oldPath ?? "" }
    public var displayPath: String { newPath ?? oldPath ?? "" }

    /// Total added / removed line counts across all hunks.
    public var addedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .addition }.count } }
    public var removedCount: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .deletion }.count } }

    public init(
        oldPath: String? = nil,
        newPath: String? = nil,
        status: DiffFileStatus = .modified,
        isBinary: Bool = false,
        hunks: [DiffHunk] = []
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.status = status
        self.isBinary = isBinary
        self.hunks = hunks
    }
}
