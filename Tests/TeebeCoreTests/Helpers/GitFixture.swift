import Foundation

/// Scaffolds throwaway git repositories in the temporary directory for hermetic
/// integration tests (TDD_PLAN §4). Auto-cleans on `cleanup()`.
final class GitFixture {
    let root: URL
    let repoURL: URL

    var repoPath: String { repoURL.path }

    init(name: String = "repo") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("teebe-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.root = base
        self.repoURL = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        initRepo()
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Git plumbing

    /// Run git synchronously in `dir` (defaults to the main repo), returning stdout.
    @discardableResult
    func git(_ args: [String], in dir: URL? = nil) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = dir ?? repoURL

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"].map { "\($0):/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" }) ?? "/usr/bin:/bin"
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try? process.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func initRepo() {
        git(["init", "-q", "-b", "main"])
        git(["config", "user.email", "test@teebe.local"])
        git(["config", "user.name", "Teebe Test"])
        git(["config", "commit.gpgsign", "false"])
    }

    // MARK: - Convenience builders

    func writeFile(_ relativePath: String, _ contents: String, in dir: URL? = nil) {
        let url = (dir ?? repoURL).appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? contents.data(using: .utf8)!.write(to: url)
    }

    func deleteFile(_ relativePath: String, in dir: URL? = nil) {
        let url = (dir ?? repoURL).appendingPathComponent(relativePath)
        try? FileManager.default.removeItem(at: url)
    }

    func stage(_ paths: [String] = ["-A"], in dir: URL? = nil) {
        git(["add"] + paths, in: dir)
    }

    func commit(_ message: String, in dir: URL? = nil) {
        git(["commit", "-q", "-m", message], in: dir)
    }

    /// Write, stage and commit in one step.
    func commitFile(_ relativePath: String, _ contents: String, message: String? = nil) {
        writeFile(relativePath, contents)
        stage([relativePath])
        commit(message ?? "add \(relativePath)")
    }

    func createBranch(_ name: String) {
        git(["branch", name])
    }

    /// Create a linked worktree at `<root>/<name>` on a new branch `branch`.
    @discardableResult
    func addWorktree(name: String, branch: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        git(["worktree", "add", "-q", "-b", branch, url.path])
        return url
    }

    func currentHead() -> String {
        git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
