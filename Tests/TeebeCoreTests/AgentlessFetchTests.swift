import Testing
import Foundation
@testable import TeebeCore

/// An automatic fetch must never reach an SSH agent, whatever SSH the repository
/// is set up to use. ssh keeps the first value it sees for an option, so the
/// agent-less options have to come before anything the user's command passes.
@Suite("Agent-less automatic fetch")
struct AgentlessFetchTests {
    let git = ProcessGitClient()
    let first = "-o BatchMode=yes -o IdentityAgent=none"

    private func automatic(inherited: [String: String] = [:], sshCommand: String? = nil) -> String? {
        ProcessGitClient.fetchEnvironment(inherited: inherited, sshCommand: sshCommand, kind: .automatic)?["GIT_SSH_COMMAND"]
    }

    // MARK: - The command an automatic fetch runs

    @Test("the options go right after the program, ahead of the repository's own")
    func optionsComeFirst() {
        #expect(automatic(sshCommand: "ssh -o IdentityAgent=/tmp/agent.sock -i ~/.ssh/work")
            == "ssh \(first) -o IdentityAgent=/tmp/agent.sock -i ~/.ssh/work")
        #expect(automatic(sshCommand: "/usr/bin/ssh -p 2222") == "/usr/bin/ssh \(first) -p 2222")
        #expect(automatic(sshCommand: "  ssh") == "ssh \(first)")
        // Git prefers the environment's command over the configured one.
        #expect(automatic(inherited: ["GIT_SSH_COMMAND": "ssh -o IdentityAgent=/tmp/a.sock"], sshCommand: "ssh -i k")
            == "ssh \(first) -o IdentityAgent=/tmp/a.sock")
        #expect(automatic() == "ssh \(first)")
    }

    @Test("a quoted program path keeps its quoting")
    func quotedProgram() {
        #expect(automatic(sshCommand: "\"/Applications/My Tools/ssh\" -i \"/keys/my key\"")
            == "\"/Applications/My Tools/ssh\" \(first) -i \"/keys/my key\"")
        #expect(automatic(sshCommand: "'/opt/acme tools/ssh' -F cfg") == "'/opt/acme tools/ssh' \(first) -F cfg")
        #expect(automatic(sshCommand: "/opt/acme\\ tools/ssh -F cfg") == "/opt/acme\\ tools/ssh \(first) -F cfg")
        #expect(automatic(sshCommand: "~/bin/ssh") == "~/bin/ssh \(first)")
    }

    @Test("a GIT_SSH program becomes a command, so it gets the options too")
    func gitSSHProgram() {
        #expect(automatic(inherited: ["GIT_SSH": "/usr/bin/ssh"]) == "'/usr/bin/ssh' \(first)")
        #expect(automatic(inherited: ["GIT_SSH": "/opt/it's mine/ssh"]) == "'/opt/it'\\''s mine/ssh' \(first)")
        // A command still wins over GIT_SSH, as in Git.
        #expect(automatic(inherited: ["GIT_SSH": "/opt/acme/plink"], sshCommand: "ssh -i k") == "ssh \(first) -i k")
    }

    @Test("an SSH program that is not recognizably ssh skips the automatic fetch")
    func unrecognizedProgram() {
        for command in ["/usr/local/bin/ssh-wrapper -i k", "plink -batch", "$HOME/bin/ssh", "FOO=1 ssh",
                        "sh -c 'ssh \"$@\"'", "\"/opt/ssh -i k", "ssh;ssh", "`which ssh`", "/opt/s*/ssh"] {
            #expect(ProcessGitClient.fetchEnvironment(inherited: [:], sshCommand: command, kind: .automatic) == nil,
                    "\(command)")
        }
        #expect(ProcessGitClient.fetchEnvironment(inherited: ["GIT_SSH": "/opt/acme/plink"], sshCommand: nil,
                                                  kind: .automatic) == nil)
    }

    @Test("a manual fetch keeps the user's command as it was and only appends batch mode")
    func manualUnchanged() {
        let manual = { (inherited: [String: String], command: String?) in
            ProcessGitClient.fetchEnvironment(inherited: inherited, sshCommand: command, kind: .manual)
        }
        #expect(manual([:], "ssh -o IdentityAgent=/tmp/agent.sock")
            == ["GIT_SSH_COMMAND": "ssh -o IdentityAgent=/tmp/agent.sock -o BatchMode=yes", "SSH_ASKPASS_REQUIRE": "never"])
        #expect(manual([:], "/usr/local/bin/ssh-wrapper -i k")?["GIT_SSH_COMMAND"]
            == "/usr/local/bin/ssh-wrapper -i k -o BatchMode=yes")
        #expect(manual(["GIT_SSH": "/opt/acme/plink"], nil) == ["SSH_ASKPASS_REQUIRE": "never"])
    }

    // MARK: - What ssh and git actually do with it

    @Test("ssh resolves no agent for an automatic fetch, even one the command and config name")
    func sshResolvesNoAgent() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let config = fixture.root.appendingPathComponent("ssh config")
        try "Host *\n  IdentityAgent /tmp/config-agent.sock\n".write(to: config, atomically: true, encoding: .utf8)
        let command = "ssh -F '\(config.path)' -o IdentityAgent=/tmp/command-agent.sock"

        let agentless = try #require(automatic(sshCommand: command))
        let resolved = Self.shell(agentless + " -G example.invalid")
        #expect(resolved.contains("\nidentityagent none\n"))
        #expect(resolved.contains("\nbatchmode yes\n"))
        // The same command run manually still reaches the agent it names.
        let manual = try #require(ProcessGitClient.fetchEnvironment(inherited: [:], sshCommand: command,
                                                                    kind: .manual)?["GIT_SSH_COMMAND"])
        #expect(Self.shell(manual + " -G example.invalid").contains("\nidentityagent /tmp/command-agent.sock\n"))
    }

    @Test("a GIT_SSH program at a path with spaces and quotes still runs, options first")
    func gitSSHProgramRuns() throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let (ssh, record) = try Self.recorder(in: fixture, directory: "it's my bin", name: "ssh")
        let command = try #require(automatic(inherited: ["GIT_SSH": ssh.path]))
        // How Git runs an SSH command: through the shell, its own arguments appended.
        _ = Self.shell(command + " \"$@\"", arguments: ["example.invalid", "git-upload-pack 'repo.git'"])
        #expect(Self.lines(record) == ["-o", "BatchMode=yes", "-o", "IdentityAgent=none",
                                       "example.invalid", "git-upload-pack 'repo.git'"])
    }

    @Test("an automatic fetch puts its options ahead of an agent in core.sshCommand")
    func fetchPutsOptionsFirst() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let (ssh, record) = try Self.recorder(in: fixture, directory: "ssh tools", name: "ssh")
        fixture.git(["remote", "add", "origin", "ssh://example.invalid/repo.git"])
        fixture.git(["config", "core.sshCommand", "'\(ssh.path)' -o IdentityAgent=/tmp/agent.sock -i /tmp/acme-key"])

        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath, kind: .automatic)
        }
        let automatic = Self.lines(record)
        #expect(Array(automatic.prefix(4)) == ["-o", "BatchMode=yes", "-o", "IdentityAgent=none"])
        #expect(Array(automatic.dropFirst(4).prefix(4)) == ["-o", "IdentityAgent=/tmp/agent.sock", "-i", "/tmp/acme-key"])

        try FileManager.default.removeItem(at: record)
        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath, kind: .manual)
        }
        let manual = Self.lines(record)
        #expect(Array(manual.prefix(6)) == ["-o", "IdentityAgent=/tmp/agent.sock", "-i", "/tmp/acme-key", "-o", "BatchMode=yes"])
        #expect(!manual.contains("IdentityAgent=none"))
    }

    @Test("an automatic fetch through a wrapper that is not ssh does not run; Refresh does")
    func wrapperSkipsAutomaticFetch() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        fixture.commitFile("a.txt", "base")
        let (wrapper, record) = try Self.recorder(in: fixture, directory: "bin", name: "acme-ssh-wrapper")
        fixture.git(["remote", "add", "origin", "ssh://example.invalid/repo.git"])
        fixture.git(["config", "core.sshCommand", wrapper.path + " -i /tmp/acme-key"])

        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath, kind: .automatic)
        }
        #expect(!FileManager.default.fileExists(atPath: record.path))

        await #expect(throws: GitError.self) {
            try await git.fetchOrigin(repoPath: fixture.repoPath, kind: .manual)
        }
        #expect(Array(Self.lines(record).prefix(4)) == ["-i", "/tmp/acme-key", "-o", "BatchMode=yes"])
    }

    // MARK: - Helpers

    /// A stand-in program that writes each argument on its own line, then fails
    /// like an unreachable host would.
    private static func recorder(in fixture: GitFixture, directory: String, name: String) throws -> (URL, URL) {
        let bin = fixture.root.appendingPathComponent(directory, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let record = fixture.root.appendingPathComponent("\(name)-calls.txt")
        let program = bin.appendingPathComponent(name)
        let quoted = "'" + record.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \(quoted)\nexit 255\n".write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        return (program, record)
    }

    private static func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Runs `command` with `/bin/sh -c`, the way Git runs an SSH command; returns stdout.
    private static func shell(_ command: String, arguments: [String] = []) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command, "sh"] + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try? process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return "\n" + (String(bytes: data, encoding: .utf8) ?? "")
    }
}
