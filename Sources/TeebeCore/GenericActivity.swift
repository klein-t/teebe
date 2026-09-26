import Darwin
import Foundation

/// Harness-agnostic activity: whatever the agent (Codex, Claude Code, Cursor,
/// Aider, Gemini CLI, a script), work shows up as files changing in the worktree
/// and processes running in it. This is the base signal for the working orb;
/// harness adapters (`AgentActivitySource`) add precision and "waiting for you".
public enum GenericActivity {
    /// How long a worktree stays working after its last file change or busy
    /// process. Agents pause to think between writes: across 3,688 gaps between
    /// consecutive file edits in real Claude Code and Codex sessions the median
    /// was 40 s and 74% were under 90 s (Claude 84%, Codex 69%). Shorter windows
    /// make the orb flicker off mid-task; running builds and tests bridge the
    /// longer gaps through the process signal.
    public static let window: TimeInterval = 90
}

/// Maps raw file-event paths to the worktrees whose files really changed:
/// Git's own bookkeeping, dependency and build output, caches and Finder
/// metadata are ignored, so a dev server rebuilding or a package install
/// flooding `node_modules` doesn't read as the agent working.
public enum WorktreeActivityRouter {
    /// Directory names that hold generated content, matched on any path
    /// component below the worktree root.
    public static let ignoredDirectories: Set<String> = [
        ".git", "node_modules", ".build", "build", "dist", "target", "DerivedData", ".swiftpm",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".cache", "coverage",
        "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".venv", "venv",
        ".gradle", "Pods"
    ]
    public static let ignoredFiles: Set<String> = [".DS_Store"]

    /// The worktrees (deepest owner) with at least one change that counts.
    public static func changedWorktrees(eventPaths: [String], among worktrees: [String]) -> Set<String> {
        var changed = Set<String>()
        for path in eventPaths {
            guard let owner = WorktreeAttribution.deepest(containing: path, among: worktrees),
                  !changed.contains(owner) else { continue }
            let root = WorktreeAttribution.normalized(owner)
            let relative = WorktreeAttribution.normalized(path).dropFirst(root.count)
            let components = relative.split(separator: "/")
            if let last = components.last, ignoredFiles.contains(String(last)) { continue }
            if components.contains(where: { ignoredDirectories.contains(String($0)) }) { continue }
            changed.insert(owner)
        }
        return changed
    }
}

/// One process whose working directory is inside a worktree.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var parentPID: Int32
    public var name: String
    public var parentName: String
    public var cwd: String
    /// Total CPU time used so far, in seconds.
    public var cpuSeconds: Double

    public init(pid: Int32, parentPID: Int32, name: String, parentName: String, cwd: String, cpuSeconds: Double) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.parentName = parentName
        self.cwd = cwd
        self.cpuSeconds = cpuSeconds
    }
}

/// Which worktrees have a process doing work in them right now.
///
/// Rule: a process counts when its cwd is inside the worktree and it used at
/// least `minCPUShare` of a core since the previous sample. Measured on the
/// user's machine, idle shells, `sleep` loops and idle dev servers use under
/// 1%, while builds, test runners and the tools agents launch use far more.
/// Not counted, whatever their CPU:
/// - Teebe and the Git commands it runs itself.
/// - Shells: an idle prompt is not work (the commands it runs are counted).
/// - Interactive agent hosts (Claude Code, Codex): their terminal UIs draw
///   continuously, 10–200 ms of CPU every 3 s even while idle, so their CPU says
///   nothing. Their work is seen through their adapters, the commands they
///   launch (which run with the worktree as cwd) and the files they write.
/// - Editors and language servers, and anything an editor spawns directly
///   (its Git polling, indexers). A shell in an editor's terminal is a shell, so
///   what runs inside it still counts.
public final class ProcessActivityProbe: @unchecked Sendable {
    public static let minCPUShare = 0.10

    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "tcsh", "csh", "ksh", "nu", "login",
                                      "tmux", "screen", "sleep"]
    static let agentHosts: Set<String> = ["claude", "codex", "codex-code-mode-host", "node_repl", "cursor-agent"]
    static let editors: Set<String> = [
        "Code Helper", "Code Helper (Plugin)", "Code Helper (Renderer)", "Electron", "Code",
        "Cursor", "Cursor Helper", "Cursor Helper (Plugin)", "Windsurf", "Windsurf Helper (Plugin)",
        "Xcode", "SourceKitService", "sourcekit-lsp", "zed", "Zed", "idea", "pycharm", "webstorm",
        "nvim", "vim", "emacs", "Sublime Text", "Nova"
    ]

    private let lock = NSLock()
    private var previous: [Int32: Double] = [:]
    private var previousAt: Date?
    private let selfPID: Int32

    /// `selfPID`: the process whose own children are not counted (Teebe).
    public init(selfPID: Int32 = getpid()) {
        self.selfPID = selfPID
    }

    /// Worktrees with a busy process, comparing against the previous call.
    /// The first call only establishes the baseline for processes it sees.
    public func activeWorktrees(among worktrees: [String], now: Date = Date()) -> Set<String> {
        let samples = Self.samples(among: worktrees)
        lock.lock()
        defer { lock.unlock() }
        let elapsed = previousAt.map { now.timeIntervalSince($0) } ?? 0
        let active = elapsed > 0 ? Self.active(samples: samples, previous: previous, elapsed: elapsed,
                                               among: worktrees, selfPID: selfPID) : []
        previous = Dictionary(samples.map { ($0.pid, $0.cpuSeconds) }, uniquingKeysWith: { first, _ in first })
        previousAt = now
        return active
    }

    /// The worktrees a process is still in, read for removal rather than for the
    /// orb: any process whose cwd is inside counts, busy or idle, whatever it is (a
    /// shell at its prompt, an agent's UI, an editor). Only Teebe and the Git
    /// commands it runs itself are left out.
    public func occupiedWorktrees(among worktrees: [String]) -> Set<String> {
        Self.occupied(samples: Self.samples(among: worktrees), among: worktrees, selfPID: selfPID)
    }

    static func occupied(samples: [ProcessSample], among worktrees: [String], selfPID: Int32) -> Set<String> {
        Set(samples.filter { $0.pid != selfPID && $0.parentPID != selfPID }
            .compactMap { WorktreeAttribution.deepest(containing: $0.cwd, among: worktrees) })
    }

    /// The pure rule, for tests. A process new since the previous sample counts
    /// all its CPU as used within `elapsed`.
    static func active(samples: [ProcessSample], previous: [Int32: Double], elapsed: TimeInterval,
                       among worktrees: [String], selfPID: Int32) -> Set<String> {
        var active = Set<String>()
        for sample in samples where !isExcluded(sample, selfPID: selfPID) {
            let used = sample.cpuSeconds - (previous[sample.pid] ?? 0)
            guard used >= minCPUShare * elapsed,
                  let owner = WorktreeAttribution.deepest(containing: sample.cwd, among: worktrees) else { continue }
            active.insert(owner)
        }
        return active
    }

    static func isExcluded(_ sample: ProcessSample, selfPID: Int32) -> Bool {
        if sample.pid == selfPID || sample.parentPID == selfPID { return true }
        let name = sample.name
        if shells.contains(name) || name.hasPrefix("-") || agentHosts.contains(name) || editors.contains(name) {
            return true
        }
        // Claude Code's native binary shows its version as the process name.
        if !name.isEmpty, name.allSatisfy({ $0.isNumber || $0 == "." }), name.contains(".") { return true }
        return editors.contains(sample.parentName)
    }

    // MARK: - Reading the process table (libproc)

    static func samples(among worktrees: [String]) -> [ProcessSample] {
        var timebase = mach_timebase_info()
        mach_timebase_info(&timebase)
        let ticksToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
        var names: [Int32: String] = [:]
        var result: [ProcessSample] = []
        for pid in allPIDs() {
            guard let cwd = workingDirectory(of: pid),
                  WorktreeAttribution.deepest(containing: cwd, among: worktrees) != nil,
                  let info = bsdInfo(of: pid), let cpu = cpuTicks(of: pid) else { continue }
            let parentName = names[info.parent] ?? bsdInfo(of: info.parent)?.name ?? ""
            names[info.parent] = parentName
            result.append(ProcessSample(pid: pid, parentPID: info.parent, name: info.name, parentName: parentName,
                                        cwd: cwd, cpuSeconds: Double(cpu) * ticksToSeconds))
        }
        return result
    }

    private static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
        return path?.isEmpty == false ? path : nil
    }

    private static func bsdInfo(of pid: Int32) -> (name: String, parent: Int32)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let name = withUnsafeBytes(of: info.pbi_name) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) }
        return (name ?? "", Int32(info.pbi_ppid))
    }

    private static func cpuTicks(of pid: Int32) -> UInt64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return info.pti_total_user + info.pti_total_system
    }
}
