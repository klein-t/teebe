import Foundation

/// Explicit argument vectors keep paths with spaces or shell punctuation literal.
enum TerminalChoice: String, CaseIterable, Identifiable {
    case terminal, cmux
    var id: String { rawValue }
    var title: String { self == .terminal ? "Terminal" : "cmux" }
    var executable: String {
        self == .terminal ? "/usr/bin/open" : "/Applications/cmux.app/Contents/Resources/bin/cmux"
    }
    func arguments(at path: String) -> [String] {
        self == .terminal ? ["-a", "Terminal", path] : ["new-workspace", "--cwd", path, "--focus", "true"]
    }
    func launch(at path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments(at: path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
