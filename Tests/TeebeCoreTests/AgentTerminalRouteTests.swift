import Foundation
import Testing
@testable import TeebeCore

@Suite("Verified agent terminal routes")
struct AgentTerminalRouteTests {
    let session = AgentTerminalSession(provider: .codex, id: "session", transcriptPath: "/logs/rollout-session.jsonl")
    let workspace = UUID()
    let surface = UUID()

    func anchor() -> TerminalRouteAnchor {
        TerminalRouteAnchor(session: session,
            process: TerminalProcessIdentity(pid: 100, uid: 501, startedSeconds: 1_000, startedMicroseconds: 10, tty: "ttys003"),
            device: 1, inode: 20, hostPID: 90, hostStartedSeconds: 900, hostStartedMicroseconds: 1,
            cmuxCLI: "/Applications/cmux.app/Contents/Resources/bin/cmux", workspace: workspace, surface: surface)
    }

    func target() -> CmuxTerminalTarget {
        CmuxTerminalTarget(window: UUID(), workspace: workspace, pane: UUID(), surface: surface, tty: "ttys003")
    }

    @Test("a unique live owner and destination must survive the second observation")
    func resolvesAndRechecks() {
        let owner = anchor()
        let destination = target()
        let probe = RouteProbe(owners: [owner, owner], destinations: [destination, destination])
        #expect(AgentTerminalResolver.resolve(session, probe: probe) == AgentTerminalRoute(anchor: owner, target: destination))
        #expect(probe.captureCalls == 2 && probe.destinationCalls == 2)
    }

    @Test("ended sessions, reused PIDs or ttys, replaced logs and changed hosts fail closed", arguments: 0..<6)
    func staleOwner(kind: Int) {
        let owner = anchor()
        var changed = owner
        switch kind {
        case 0: changed.process.startedSeconds += 1
        case 1: changed.process.tty = "ttys004"
        case 2: changed.inode += 1
        case 3: changed.hostStartedMicroseconds += 1
        case 4: changed.surface = UUID()
        default: break
        }
        let probe = RouteProbe(owners: [owner, kind == 5 ? nil : changed], destinations: [target()])
        #expect(AgentTerminalResolver.resolve(session, probe: probe) == nil)
        #expect(probe.destinationCalls == 1)
    }

    @Test("no live owner or supported terminal is a fallback, without a target query")
    func absentOwner() {
        let probe = RouteProbe(owners: [nil], destinations: [])
        #expect(AgentTerminalResolver.resolve(session, probe: probe) == nil)
        #expect(probe.destinationCalls == 0)
    }

    @Test("missing or closed destinations and changed surface maps fall back")
    func unavailableDestination() {
        let owner = anchor()
        let probe = RouteProbe(owners: [owner], destinations: [nil])
        #expect(AgentTerminalResolver.resolve(session, probe: probe) == nil)
        let changed = RouteProbe(owners: [owner, owner], destinations: [target(), target()])
        #expect(AgentTerminalResolver.resolve(session, probe: changed) == nil)
    }

    @Test("an expired deadline cannot start inspection")
    func expired() {
        let probe = RouteProbe(owners: [anchor()], destinations: [target()])
        #expect(AgentTerminalResolver.resolve(session, probe: probe, deadline: TerminalRouteDeadline(seconds: 0)) == nil)
        #expect(probe.captureCalls == 0)
    }

    @Test("mapping uses tty and inherited surface identity across all windows")
    func mapping() throws {
        let expected = target()
        let tree = try treeData([expected])
        #expect(CmuxTerminalMapping.target(in: tree, tty: "/dev/ttys003", workspace: workspace, surface: surface) == expected)
        #expect(CmuxTerminalMapping.target(in: tree, tty: "ttys004", workspace: workspace, surface: surface) == nil)
        #expect(CmuxTerminalMapping.target(in: tree, tty: "ttys003", workspace: UUID(), surface: surface) == nil)
        #expect(CmuxTerminalMapping.target(in: tree, tty: "ttys003", workspace: workspace, surface: UUID()) == nil)
    }

    @Test("duplicate tty reports, browser surfaces, short refs and malformed trees are rejected")
    func ambiguousMapping() throws {
        let expected = target()
        for tree in [try treeData([expected, target()]), try treeData([expected], type: "browser"),
                     Data(#"{"windows":[{"id":"window:1","workspaces":[] }]}"#.utf8), Data("{}".utf8)] {
            #expect(CmuxTerminalMapping.target(in: tree, tty: "ttys003", workspace: workspace, surface: surface) == nil)
        }
        #expect(TerminalProcessIdentity.normalizedTTY("/dev/ttys001; echo no") == nil)
    }

    private func treeData(_ targets: [CmuxTerminalTarget], type: String = "terminal") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["windows": targets.map { target in
            ["id": target.window.uuidString, "workspaces": [
                ["id": target.workspace.uuidString, "panes": [
                    ["id": target.pane.uuidString, "surfaces": [
                        ["id": target.surface.uuidString, "type": type, "tty": "/dev/" + target.tty]
                    ]]
                ]]
            ]]
        }])
    }
}

private final class RouteProbe: AgentTerminalProbe {
    var owners: [TerminalRouteAnchor?]
    var destinations: [CmuxTerminalTarget?]
    var captureCalls = 0
    var destinationCalls = 0

    init(owners: [TerminalRouteAnchor?], destinations: [CmuxTerminalTarget?]) {
        self.owners = owners
        self.destinations = destinations
    }

    func capture(_ session: AgentTerminalSession, deadline: TerminalRouteDeadline) -> TerminalRouteAnchor? {
        captureCalls += 1
        return owners.isEmpty ? nil : owners.removeFirst()
    }

    func destination(for anchor: TerminalRouteAnchor, deadline: TerminalRouteDeadline) -> CmuxTerminalTarget? {
        destinationCalls += 1
        return destinations.isEmpty ? nil : destinations.removeFirst()
    }
}
