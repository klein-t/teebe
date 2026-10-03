import Foundation

/// `GitClient` implementation that shells out to the system `git` via `Process`
/// (TECH_SPEC §1). All typed methods route raw output through the pure parsers.
public struct ProcessGitClient: GitClient {
    /// Process waits and pipe reads both use dispatch workers. An unbounded burst
    /// can occupy every worker with waits, starving the readers they depend on.
    /// Share this limit across clients, so many worktrees cannot exhaust the pool.
    private static let processQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "teebe.git"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()

    public init() {}

    // MARK: - Discovery

    public func worktrees(repoPath: String) async throws -> [Worktree] {
        let result = try await runChecked(["worktree", "list", "--porcelain"], in: repoPath)
        return WorktreeListParser.parse(result.stdoutString)
    }

    public func branches(repoPath: String) async throws -> [Branch] {
        let result = try await runChecked(
            ["for-each-ref", "--format=\(BranchListParser.format)", "refs/heads", "refs/remotes"],
            in: repoPath
        )
        return BranchListParser.parse(result.stdoutString)
    }

    // MARK: - Status & changes

    /// Untracked files and submodules are always counted, whatever the repository's
    /// status settings, exactly as the removal check counts them: a setting that
    /// hides them must not make a worktree read as clean.
    public func status(worktreePath: String) async throws -> StatusResult {
        let result = try await runChecked(Self.statusArguments, in: worktreePath)
        return StatusParser.parse(result.stdoutString)
    }

    static let statusArguments = [
        "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=none"
    ]

    // MARK: - Diffs

    public func workingDiff(worktreePath: String, path: String, staged: Bool) async throws -> DiffFile? {
        var args = ["diff"]
        if staged { args.append("--staged") }
        args.append(contentsOf: ["--", path])
        let result = try await runChecked(args, in: worktreePath)
        return DiffParser.parse(result.stdoutString).first
    }

    // MARK: - Writes

    public func stage(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["add", "--"] + paths, in: worktreePath, interruptible: false)
    }

    public func unstage(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["restore", "--staged", "--"] + paths, in: worktreePath, interruptible: false)
    }

    public func discardWorking(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["restore", "--"] + paths, in: worktreePath, interruptible: false)
    }

    public func discardUntracked(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["clean", "-f", "--"] + paths, in: worktreePath, interruptible: false)
    }

    public func commit(worktreePath: String, message: String) async throws {
        _ = try await runChecked(["commit", "-m", message], in: worktreePath, interruptible: false)
    }

    // MARK: - Worktree management

    public func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool, startPoint: String?) async throws {
        let args = Self.worktreeAddArguments(path: path, branch: branch, createBranch: createBranch, startPoint: startPoint)
        _ = try await runChecked(args, in: repoPath, interruptible: false)
    }

    /// The `git worktree add` argument list. Pure, so the ordering git cares about
    /// (`-b <branch> <path> <start-point>`) is covered by a test.
    /// A branch made from a start point gets `--no-track`: from a remote start point
    /// such as `origin/main` git would otherwise make that its upstream, so a plain
    /// push would fail on the name mismatch or, with `push.default=upstream`, push
    /// the new branch into `main`.
    static func worktreeAddArguments(path: String, branch: String?, createBranch: Bool, startPoint: String?) -> [String] {
        var args = ["worktree", "add"]
        let startPoint = startPoint.flatMap { $0.isEmpty ? nil : $0 }
        if createBranch, let branch {
            if startPoint != nil { args.append("--no-track") }
            args.append(contentsOf: ["-b", branch])
        }
        args.append(path)
        if createBranch, branch != nil, let startPoint {
            args.append(startPoint)
        } else if let branch, !createBranch {
            args.append(branch)
        }
        return args
    }

    public func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        _ = try await runChecked(args, in: repoPath, interruptible: false)
    }

    // MARK: - Remotes

    public func fetchOrigin(repoPath: String, kind: FetchKind) async throws {
        // A read of the remote, so it stays interruptible. The extra environment
        // makes every credential path fail fast rather than waiting on a prompt,
        // through the SSH command the repository already uses.
        let configured = try? await run(["config", "--get", "core.sshCommand"], in: repoPath)
        let sshCommand = configured.flatMap { $0.succeeded ? $0.stdoutString : nil }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // nil: an automatic fetch through this SSH program could still reach the
        // agent, so it does not run at all. Like any automatic failure, that is silent.
        guard let environment = Self.fetchEnvironment(inherited: ProcessInfo.processInfo.environment,
                                                      sshCommand: sshCommand?.isEmpty == false ? sshCommand : nil,
                                                      kind: kind) else {
            throw GitError.commandFailed(command: Self.fetchArguments, exitCode: -1,
                                         stderr: "The SSH program is not ssh, so it may use the SSH agent.")
        }
        let result = try await run(Self.fetchArguments, in: repoPath, extraEnvironment: environment)
        guard result.succeeded else {
            throw Self.mapError(arguments: result.arguments, directory: repoPath, result: result)
        }
    }

    /// Pruning drops tracking refs of branches deleted on the remote, which is what
    /// lets a worktree's branch read as deleted there.
    static let fetchArguments = ["fetch", "--quiet", "--prune", "origin"]

    /// What a background fetch adds to the environment: SSH in batch mode, so it
    /// fails instead of asking for a passphrase or a host key, and no askpass
    /// dialog. The user's own SSH command (a per-repository key in
    /// `core.sshCommand`, or `GIT_SSH_COMMAND`, which Git prefers) is kept and only
    /// gets the batch option; for a `.manual` fetch a `GIT_SSH` program is left
    /// alone, since setting a command would replace it.
    ///
    /// An `.automatic` fetch also runs without the SSH agent, both the one in
    /// `SSH_AUTH_SOCK` and one named by `IdentityAgent`: agents such as 1Password's
    /// or Secretive ask for approval on every use, and batch mode does not stop
    /// that. ssh keeps the first value it is given for an option, so the options go
    /// straight after the program, ahead of the user's own arguments and of the SSH
    /// config. That needs a program that is recognizably ssh; with any other (a
    /// wrapper script, plink) there is no telling what reaches the agent, so the
    /// result is nil and the fetch does not run. Keys the agent alone holds also
    /// fail the fetch, which is silent; the user's own Refresh goes through the agent.
    static func fetchEnvironment(inherited: [String: String], sshCommand: String?, kind: FetchKind) -> [String: String]? {
        var environment = ["SSH_ASKPASS_REQUIRE": "never"]
        let command = inherited["GIT_SSH_COMMAND"].flatMap { $0.isEmpty ? nil : $0 } ?? sshCommand
        guard kind == .automatic else {
            if let command {
                environment["GIT_SSH_COMMAND"] = command + " -o BatchMode=yes"
            } else if inherited["GIT_SSH"] == nil {
                environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
            }
            return environment
        }
        guard let agentless = agentlessSSHCommand(command: command, program: inherited["GIT_SSH"]) else { return nil }
        environment["SSH_AUTH_SOCK"] = ""
        environment["GIT_SSH_COMMAND"] = agentless
        return environment
    }

    static let agentlessOptions = "-o BatchMode=yes -o IdentityAgent=none"

    /// The SSH command an automatic fetch runs, in the order Git picks one: a
    /// command (from the environment or `core.sshCommand`), else a `GIT_SSH`
    /// program, else plain `ssh`. nil when the program is not recognizably ssh.
    static func agentlessSSHCommand(command: String?, program: String?) -> String? {
        if let command {
            guard let (word, rest) = sshProgramWord(in: command) else { return nil }
            return word + " " + agentlessOptions + rest
        }
        if let program, !program.isEmpty {
            guard (program as NSString).lastPathComponent == "ssh" else { return nil }
            return "'" + program.replacingOccurrences(of: "'", with: "'\\''") + "' " + agentlessOptions
        }
        return "ssh " + agentlessOptions
    }

    /// Splits a shell command into its first word, as written, and the rest, when
    /// that word names a program called `ssh`. nil when the shell would expand the
    /// word or read it as anything but a plain path (a variable, a glob, an
    /// assignment, an operator), since then what actually runs can't be known.
    static func sshProgramWord(in command: String) -> (word: Substring, rest: Substring)? {
        let text = command.drop { $0.isWhitespace }
        var value = ""
        var quote: Character?
        var index = text.startIndex
        while index < text.endIndex, quote != nil || !text[index].isWhitespace {
            if quote == nil {
                guard let next = unquotedStep(text, at: index, quote: &quote, value: &value) else { return nil }
                index = next
            } else {
                guard quotedStep(text[index], quote: &quote, value: &value) else { return nil }
                index = text.index(after: index)
            }
        }
        guard quote == nil, (value as NSString).lastPathComponent == "ssh" else { return nil }
        return (text[..<index], text[index...])
    }

    private static let shellSpecial = Set("$`;|&<>(){}*?[=#")

    /// One character inside quotes. Expansions in double quotes are refused, and
    /// so are backslashes there, rather than reproduce which ones the shell keeps.
    private static func quotedStep(_ char: Character, quote: inout Character?, value: inout String) -> Bool {
        if char == quote {
            quote = nil
        } else if quote == "\"" && "$`\\".contains(char) {
            return false
        } else {
            value.append(char)
        }
        return true
    }

    /// One character outside quotes; returns where the next one starts.
    private static func unquotedStep(
        _ text: Substring, at index: Substring.Index, quote: inout Character?, value: inout String
    ) -> Substring.Index? {
        let char = text[index]
        let after = text.index(after: index)
        if char == "'" || char == "\"" {
            quote = char
        } else if char == "\\" {
            guard after < text.endIndex, !text[after].isNewline else { return nil }
            value.append(text[after])
            return text.index(after: after)
        } else if shellSpecial.contains(char) {
            return nil
        } else {
            value.append(char)
        }
        return after
    }

    // MARK: - Low-level

    @discardableResult
    public func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        try await run(arguments, in: directory, extraEnvironment: [:])
    }

    @discardableResult
    private func run(
        _ arguments: [String], in directory: String, extraEnvironment: [String: String]
    ) async throws -> GitInvocationResult {
        let invocation = Invocation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.processQueue.addOperation {
                    do {
                        continuation.resume(returning: try Self.execute(
                            arguments, in: directory, as: invocation, extraEnvironment: extraEnvironment))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            invocation.cancel()
        }
    }

    /// Runs a git command that must not be interrupted once it has started: a write
    /// killed halfway leaves the repository, the index or the worktree half-changed.
    /// Callers check for cancellation *before* asking for one of these.
    @discardableResult
    private func runUninterrupted(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        try await withCheckedThrowingContinuation { continuation in
            Self.processQueue.addOperation {
                do {
                    continuation.resume(returning: try Self.execute(arguments, in: directory, as: Invocation()))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs a git command and throws a mapped `GitError` on non-zero exit.
    @discardableResult
    private func runChecked(
        _ arguments: [String], in directory: String, interruptible: Bool = true
    ) async throws -> GitInvocationResult {
        let result = interruptible
            ? try await run(arguments, in: directory)
            : try await runUninterrupted(arguments, in: directory)
        guard result.succeeded else {
            throw Self.mapError(arguments: arguments, directory: directory, result: result)
        }
        return result
    }

    // MARK: - Process execution (blocking; called off the main thread)

    private static func execute(
        _ arguments: [String], in directory: String, as invocation: Invocation,
        extraEnvironment: [String: String] = [:]
    ) throws -> GitInvocationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // `core.quotepath=false` keeps non-ASCII paths literal (avoids octal
        // escaping) so parsers see real UTF-8 filenames.
        process.arguments = ["git", "-c", "core.quotepath=false"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)

        var environment = ProcessInfo.processInfo.environment
        let extraPath = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
        environment["PATH"] = (environment["PATH"].map { "\($0):\(extraPath)" }) ?? extraPath
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extraEnvironment) { _, extra in extra }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently to avoid a full-buffer deadlock.
        let outData = Buffer()
        let errData = Buffer()
        let group = DispatchGroup()
        let readQueue = DispatchQueue(label: "teebe.git.read", attributes: .concurrent)
        group.enter()
        readQueue.async { outData.value = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        readQueue.async { errData.value = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        do {
            try invocation.launch(process)
        } catch {
            // Nothing will ever write to these pipes, so release the readers.
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            group.wait()
            throw error
        }
        process.waitUntilExit()
        invocation.finish()
        // A terminated command has no meaningful output, and a grandchild that
        // inherited the pipes may still hold them open, so do not wait for the reads.
        guard !invocation.wasCancelled else { throw CancellationError() }
        group.wait()

        return GitInvocationResult(
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: outData.value,
            standardError: String(decoding: errData.value, as: UTF8.self)
        )
    }

    /// Output collected on the reader queues; boxed so the result is never read
    /// while a reader may still be writing to it.
    private final class Buffer: @unchecked Sendable {
        var value = Data()
    }

    /// Owns one running `git` process so a cancelling task can terminate it.
    /// Launching holds the lock, so a cancellation can never reach a process that
    /// has not started yet.
    private final class Invocation: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func launch(_ process: Process) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            do {
                try process.run()
            } catch {
                let directory = process.currentDirectoryURL?.path ?? ""
                var isDirectory: ObjCBool = false
                let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) && isDirectory.boolValue
                throw ProcessGitClient.launchFailure(directory: directory, directoryExists: exists)
            }
            self.process = process
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            running?.terminate()
        }

        func finish() {
            lock.lock()
            process = nil
            lock.unlock()
        }
    }

    /// Why `git` could not be started: a working directory that is gone (a
    /// deleted worktree) is the usual cause; only otherwise is git itself missing.
    static func launchFailure(directory: String, directoryExists: Bool) -> GitError {
        directoryExists ? .executableNotFound : .workingDirectoryMissing(path: directory)
    }

    private static func mapError(arguments: [String], directory: String, result: GitInvocationResult) -> GitError {
        let stderr = result.standardError.lowercased()
        if stderr.contains("not a git repository") {
            return .notAGitRepository(path: directory)
        }
        if stderr.contains("index.lock") || (stderr.contains(".lock") && stderr.contains("unable to create")) {
            return .lockedIndex(path: directory)
        }
        return .commandFailed(command: ["git"] + arguments, exitCode: result.exitCode, stderr: result.standardError)
    }
}
