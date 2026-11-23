import Foundation
import Testing
import TeebeCore
@testable import Teebe

/// Explicit opt-in diagnostic. It never calls the focus client or activates an app.
@Suite("Terminal resolve-only diagnostic")
struct TerminalResolveDryRunTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TEEBE_TERMINAL_DRY_RUN_LOG"] != nil))
    func resolveOnly() throws {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["TEEBE_TERMINAL_DRY_RUN_LOG"])
        let id = try #require(env["TEEBE_TERMINAL_DRY_RUN_ID"])
        let provider = try #require(env["TEEBE_TERMINAL_DRY_RUN_PROVIDER"].flatMap(AgentTerminalSession.Provider.init(rawValue:)))
        let session = AgentTerminalSession(provider: provider, id: id,
                                           transcriptPath: URL(fileURLWithPath: path).resolvingSymlinksInPath().path,
                                           claudeProjectsPath: provider == .claude ? AgentSessionScanner.configuredProjectsRoot().path : nil)
        let start = ProcessInfo.processInfo.systemUptime
        let route = AgentTerminalResolver.resolve(session, probe: NativeTerminalProbe())
        print("TEEBE_TERMINAL_IDENTITY_SOURCE " + (provider == .claude ? "claude-registry" : "codex-transcript-owner"))
        if let target = route?.target {
            print("TEEBE_TERMINAL_TARGET cmux window=\(target.window) workspace=\(target.workspace) "
                  + "pane=\(target.pane) surface=\(target.surface) tty=\(target.tty)")
        } else {
            print("TEEBE_TERMINAL_TARGET teebe (no verified live cmux destination)")
        }
        print(String(format: "TEEBE_TERMINAL_RESOLVE_SECONDS %.3f", ProcessInfo.processInfo.systemUptime - start))
    }
}
