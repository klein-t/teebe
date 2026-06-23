import Foundation

/// `GitClient` implementation that shells out to the system `git` via `Process`
/// (TECH_SPEC §1). All typed methods route raw output through the pure parsers.
public struct ProcessGitClient: GitClient {
    /// Queue used to bridge blocking `Process` calls into async/await.
    private let queue: DispatchQueue

    public init() {
        self.queue = DispatchQueue(label: "teebe.git", qos: .userInitiated, attributes: .concurrent)
    }

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

    public func status(worktreePath: String) async throws -> StatusResult {
        let result = try await runChecked(["status", "--porcelain=v2", "--branch", "-z"], in: worktreePath)
        return StatusParser.parse(result.stdoutString)
    }

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
        _ = try await runChecked(["add", "--"] + paths, in: worktreePath)
    }

    public func unstage(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["restore", "--staged", "--"] + paths, in: worktreePath)
    }

    public func discardWorking(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["restore", "--"] + paths, in: worktreePath)
    }

    public func discardUntracked(worktreePath: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await runChecked(["clean", "-f", "--"] + paths, in: worktreePath)
    }

    public func commit(worktreePath: String, message: String) async throws {
        _ = try await runChecked(["commit", "-m", message], in: worktreePath)
    }

    // MARK: - Worktree management

    public func addWorktree(repoPath: String, path: String, branch: String?, createBranch: Bool) async throws {
        var args = ["worktree", "add"]
        if createBranch, let branch { args.append(contentsOf: ["-b", branch]) }
        args.append(path)
        if let branch, !createBranch { args.append(branch) }
        _ = try await runChecked(args, in: repoPath)
    }

    public func removeWorktree(repoPath: String, worktreePath: String, force: Bool) async throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        _ = try await runChecked(args, in: repoPath)
    }

    // MARK: - Low-level

    @discardableResult
    public func run(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try Self.execute(arguments, in: directory))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Runs a git command and throws a mapped `GitError` on non-zero exit.
    @discardableResult
    private func runChecked(_ arguments: [String], in directory: String) async throws -> GitInvocationResult {
        let result = try await run(arguments, in: directory)
        guard result.succeeded else {
            throw Self.mapError(arguments: arguments, directory: directory, result: result)
        }
        return result
    }

    // MARK: - Process execution (blocking; called off the main thread)

    private static func execute(_ arguments: [String], in directory: String) throws -> GitInvocationResult {
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
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Drain both pipes concurrently to avoid a full-buffer deadlock.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        let readQueue = DispatchQueue(label: "teebe.git.read", attributes: .concurrent)
        group.enter()
        readQueue.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        group.enter()
        readQueue.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave() }

        do {
            try process.run()
        } catch {
            throw GitError.executableNotFound
        }
        process.waitUntilExit()
        group.wait()

        return GitInvocationResult(
            arguments: arguments,
            exitCode: process.terminationStatus,
            standardOutput: outData,
            standardError: String(decoding: errData, as: UTF8.self)
        )
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
