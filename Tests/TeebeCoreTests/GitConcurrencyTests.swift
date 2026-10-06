import Foundation
import Testing
@testable import TeebeCore

struct GitConcurrencyTests {
    @Test("many clients drain stdout and stderr without starving their readers")
    func concurrentOutput() async throws {
        let directory = FileManager.default.temporaryDirectory.path
        // Each stream exceeds a pipe buffer. Waiting for exit without allowing
        // readers to run deadlocks; separate clients must share the same limit.
        let script = #"!/usr/bin/awk 'BEGIN { for (i=0;i<8192;i++) { print "out"; print "err" > "/dev/stderr" } }'"#
        try await withThrowingTaskGroup(of: GitInvocationResult.self) { group in
            for _ in 0..<48 {
                group.addTask {
                    try await ProcessGitClient().run(["-c", "alias.emit=\(script)", "emit"], in: directory)
                }
            }
            var completed = 0
            for try await result in group {
                #expect(result.succeeded)
                #expect(result.standardOutput.count == 32_768)
                #expect(result.standardError.utf8.count == 32_768)
                completed += 1
            }
            #expect(completed == 48)
        }
    }
}
