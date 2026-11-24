import AppKit
import Foundation
import TeebeCore

/// Click-only navigation. Process inspection and cmux commands never run on the
/// main actor. Expired work cannot start another focus command after fallback.
enum AgentTerminalJump {
    @MainActor
    static func open(_ session: AgentTerminalSession) async -> Bool {
        let deadline = TerminalRouteDeadline()
        let anchor = await bounded(deadline: deadline) {
            let probe = NativeTerminalProbe()
            guard let route = AgentTerminalResolver.resolve(session, probe: probe, deadline: deadline),
                  let socket = probe.controlSocket(route.anchor.hostPID, deadline: deadline),
                  deadline.remaining > 0,
                  CmuxTerminalClient(cli: route.anchor.cmuxCLI, socket: socket).focus(route.target, deadline: deadline)
            else { return nil }
            return route.anchor
        }
        guard let anchor, deadline.remaining > 0,
              let host = NativeTerminalProcess.bsdInfo(anchor.hostPID),
              host.pbi_start_tvsec == anchor.hostStartedSeconds, host.pbi_start_tvusec == anchor.hostStartedMicroseconds,
              let application = NSRunningApplication(processIdentifier: anchor.hostPID),
              application.bundleIdentifier == "com.cmuxterm.app", !application.isTerminated else { return false }
        NSApp.yieldActivation(to: application)
        return application.activate(from: .current, options: [])
    }

    /// Unlike a task-group race, this does not wait for an uncooperative native
    /// read to finish. The same deadline must guard every side effect in work.
    static func bounded(deadline: TerminalRouteDeadline,
                        work: @escaping @Sendable () -> TerminalRouteAnchor?) async -> TerminalRouteAnchor? {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                completion.finish(deadline.remaining > 0 ? result : nil)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + deadline.remaining) {
                completion.finish(nil)
            }
        }
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<TerminalRouteAnchor?, Never>?

        init(_ continuation: CheckedContinuation<TerminalRouteAnchor?, Never>) { self.continuation = continuation }

        func finish(_ value: TerminalRouteAnchor?) {
            let pending = lock.withLock {
                let pending = continuation
                continuation = nil
                return pending
            }
            pending?.resume(returning: value)
        }
    }
}
