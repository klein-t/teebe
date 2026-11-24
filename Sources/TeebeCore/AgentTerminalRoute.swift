import Foundation

/// Provenance from the exact log supplying an agent row. Never inferred from cwd.
/// Kept in memory only, so notification clicks can use the same resolver later.
public struct AgentTerminalSession: Equatable, Sendable {
    public enum Provider: String, Sendable { case claude, codex }
    public var provider: Provider
    public var id: String
    public var transcriptPath: String
    /// The projects directory used by the scanner, not a global default.
    public var claudeProjectsPath: String?

    public init(provider: Provider, id: String, transcriptPath: String, claudeProjectsPath: String? = nil) {
        self.provider = provider
        self.id = id
        self.transcriptPath = WorktreeAttribution.normalized(transcriptPath)
        self.claudeProjectsPath = claudeProjectsPath.map(WorktreeAttribution.normalized)
    }

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 256 && !id.contains("\0")
            && transcriptPath.hasPrefix("/") && transcriptPath.utf8.count <= 4_096 && !transcriptPath.contains("\0")
    }
}

public struct TerminalProcessIdentity: Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt32
    public var startedSeconds: UInt64
    public var startedMicroseconds: UInt64
    public var tty: String

    public init(pid: Int32, uid: UInt32, startedSeconds: UInt64, startedMicroseconds: UInt64, tty: String) {
        self.pid = pid
        self.uid = uid
        self.startedSeconds = startedSeconds
        self.startedMicroseconds = startedMicroseconds
        self.tty = tty
    }

    public static func normalizedTTY(_ value: String) -> String? {
        let name = value.hasPrefix("/dev/") ? String(value.dropFirst(5)) : value
        guard name.range(of: "^ttys[0-9]{3,}$", options: .regularExpression) != nil else { return nil }
        return name
    }
}

/// Both process start times prevent PID reuse; the device/inode prevents log replacement.
public struct TerminalRouteAnchor: Equatable, Sendable {
    public var session: AgentTerminalSession
    public var process: TerminalProcessIdentity
    public var device: UInt64
    public var inode: UInt64
    public var hostPID: Int32
    public var hostStartedSeconds: UInt64
    public var hostStartedMicroseconds: UInt64
    public var cmuxCLI: String
    public var workspace: UUID
    public var surface: UUID

    public init(session: AgentTerminalSession, process: TerminalProcessIdentity, device: UInt64, inode: UInt64,
                hostPID: Int32, hostStartedSeconds: UInt64, hostStartedMicroseconds: UInt64,
                cmuxCLI: String, workspace: UUID, surface: UUID) {
        self.session = session
        self.process = process
        self.device = device
        self.inode = inode
        self.hostPID = hostPID
        self.hostStartedSeconds = hostStartedSeconds
        self.hostStartedMicroseconds = hostStartedMicroseconds
        self.cmuxCLI = cmuxCLI
        self.workspace = workspace
        self.surface = surface
    }
}

public struct CmuxTerminalTarget: Equatable, Sendable {
    public var window: UUID
    public var workspace: UUID
    public var pane: UUID
    public var surface: UUID
    public var tty: String

    public init(window: UUID, workspace: UUID, pane: UUID, surface: UUID, tty: String) {
        self.window = window
        self.workspace = workspace
        self.pane = pane
        self.surface = surface
        self.tty = tty
    }
}

/// A monotonic deadline shared by every subprocess, including revalidation and focus.
public struct TerminalRouteDeadline: Sendable {
    private let end: TimeInterval
    public init(seconds: TimeInterval = 2) { end = ProcessInfo.processInfo.systemUptime + max(0, min(seconds, 2)) }
    public var remaining: TimeInterval { max(0, end - ProcessInfo.processInfo.systemUptime) }
}

public protocol AgentTerminalProbe {
    func capture(_ session: AgentTerminalSession, deadline: TerminalRouteDeadline) -> TerminalRouteAnchor?
    func destination(for anchor: TerminalRouteAnchor, deadline: TerminalRouteDeadline) -> CmuxTerminalTarget?
}

public struct AgentTerminalRoute: Equatable, Sendable {
    public var anchor: TerminalRouteAnchor
    public var target: CmuxTerminalTarget
}

/// Resolution is synchronous so callers explicitly choose an off-main executor.
/// Nothing here polls, caches destinations, registers sessions or changes focus.
public enum AgentTerminalResolver {
    public static func resolve(_ session: AgentTerminalSession, probe: any AgentTerminalProbe,
                               deadline: TerminalRouteDeadline = TerminalRouteDeadline()) -> AgentTerminalRoute? {
        guard session.isValid, deadline.remaining > 0,
              let anchor = probe.capture(session, deadline: deadline),
              let target = probe.destination(for: anchor, deadline: deadline),
              revalidate(AgentTerminalRoute(anchor: anchor, target: target), probe: probe, deadline: deadline)
        else { return nil }
        return AgentTerminalRoute(anchor: anchor, target: target)
    }

    public static func revalidate(_ route: AgentTerminalRoute, probe: any AgentTerminalProbe,
                                  deadline: TerminalRouteDeadline) -> Bool {
        deadline.remaining > 0 && probe.capture(route.anchor.session, deadline: deadline) == route.anchor
            && probe.destination(for: route.anchor, deadline: deadline) == route.target && deadline.remaining > 0
    }
}

/// Maps only a unique terminal tty, corroborated by the live owner's inherited
/// cmux surface identity. A stale tty report cannot redirect a new process.
public enum CmuxTerminalMapping {
    public static func target(in data: Data, tty: String, workspace: UUID, surface: UUID) -> CmuxTerminalTarget? {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = root["windows"] as? [[String: Any]],
              let tty = TerminalProcessIdentity.normalizedTTY(tty) else { return nil }
        var matches: [CmuxTerminalTarget] = []
        for window in windows {
            guard let windowID = identifier(window), let workspaces = window["workspaces"] as? [[String: Any]] else { return nil }
            for space in workspaces {
                guard let workspaceID = identifier(space), let panes = space["panes"] as? [[String: Any]] else { return nil }
                for pane in panes {
                    guard let paneID = identifier(pane), let surfaces = pane["surfaces"] as? [[String: Any]] else { return nil }
                    for item in surfaces where (item["tty"] as? String).flatMap(TerminalProcessIdentity.normalizedTTY) == tty {
                        guard item["type"] as? String == "terminal", let surfaceID = identifier(item) else { return nil }
                        matches.append(CmuxTerminalTarget(window: windowID, workspace: workspaceID,
                                                          pane: paneID, surface: surfaceID, tty: tty))
                    }
                }
            }
        }
        guard matches.count == 1, matches[0].workspace == workspace, matches[0].surface == surface else { return nil }
        return matches[0]
    }

    private static func identifier(_ object: [String: Any]) -> UUID? {
        (object["id"] as? String).flatMap(UUID.init(uuidString:))
    }
}
