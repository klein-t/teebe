import Foundation
import TeebeCore

struct CmuxTerminalClient {
    let cli: String
    let socket: String
    var run: (String, [String], TerminalRouteDeadline) -> Data? = {
        TerminalCommand.read($0, $1, deadline: $2)
    }

    func destination(for anchor: TerminalRouteAnchor, deadline: TerminalRouteDeadline) -> CmuxTerminalTarget? {
        guard let tree = run(cli, prefix + ["--json", "--id-format", "uuids", "tree", "--all"], deadline) else { return nil }
        return CmuxTerminalMapping.target(in: tree, tty: anchor.process.tty, workspace: anchor.workspace, surface: anchor.surface)
    }

    /// All targets are UUIDs from a freshly verified tree. No command creates a terminal.
    func focus(_ target: CmuxTerminalTarget, deadline: TerminalRouteDeadline) -> Bool {
        let window = ["--window", target.window.uuidString]
        let workspace = ["--workspace", target.workspace.uuidString] + window
        let commands = [
            ["focus-window"] + window,
            ["select-workspace"] + workspace,
            ["focus-pane", "--pane", target.pane.uuidString] + workspace,
            ["focus-panel", "--panel", target.surface.uuidString] + workspace
        ]
        for command in commands {
            guard deadline.remaining > 0, run(cli, prefix + command, deadline) != nil else { return false }
        }
        return deadline.remaining > 0
    }

    private var prefix: [String] { ["--socket", socket] }
}
