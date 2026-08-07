import Foundation
import Testing
@testable import TeebeCore

@Suite("ClaudeHookInstaller")
struct ClaudeHookInstallerTests {
    // MARK: - Pure merge logic

    @Test("empty settings gain the ping hook on every event")
    func installsIntoEmpty() throws {
        let merged = try #require(ClaudeHookInstaller.settingsInstallingPing(into: [:]))
        let hooks = try #require(merged["hooks"] as? [String: Any])
        for event in ClaudeHookInstaller.events {
            let groups = try #require(hooks[event] as? [[String: Any]], "missing \(event)")
            let commands = groups
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String }
            #expect(commands.contains(ClaudeHookInstaller.pingCommand))
        }
    }

    @Test("existing hooks and unrelated settings survive the merge untouched")
    func preservesExisting() throws {
        let settings: [String: Any] = [
            "model": "opus",
            "hooks": [
                "Stop": [
                    ["hooks": [["type": "command", "command": "say done"]]]
                ],
                "PreToolUse": [
                    ["matcher": "Bash", "hooks": [["type": "command", "command": "audit.sh"]]]
                ]
            ]
        ]
        let merged = try #require(ClaudeHookInstaller.settingsInstallingPing(into: settings))
        #expect(merged["model"] as? String == "opus")
        let hooks = try #require(merged["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        let stopCommands = stop
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(stopCommands.contains("say done"))
        #expect(stopCommands.contains(ClaudeHookInstaller.pingCommand))
        // Unrelated event untouched.
        let pre = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(pre.count == 1)
    }

    @Test("already fully installed returns nil (idempotent)")
    func idempotent() throws {
        let first = try #require(ClaudeHookInstaller.settingsInstallingPing(into: [:]))
        #expect(ClaudeHookInstaller.isInstalled(in: first))
        #expect(ClaudeHookInstaller.settingsInstallingPing(into: first) == nil)
    }

    @Test("a partially installed settings gains only the missing events")
    func partialInstall() throws {
        var settings = try #require(ClaudeHookInstaller.settingsInstallingPing(into: [:]))
        var hooks = settings["hooks"] as! [String: Any]
        hooks["UserPromptSubmit"] = nil   // drop one event
        settings["hooks"] = hooks
        #expect(!ClaudeHookInstaller.isInstalled(in: settings))

        let merged = try #require(ClaudeHookInstaller.settingsInstallingPing(into: settings))
        let mergedHooks = merged["hooks"] as! [String: Any]
        // Stop was already installed: still exactly one teebe group there.
        let stop = mergedHooks["Stop"] as! [[String: Any]]
        let teebeStopGroups = stop.filter {
            (($0["hooks"] as? [[String: Any]]) ?? [])
                .contains { ($0["command"] as? String) == ClaudeHookInstaller.pingCommand }
        }
        #expect(teebeStopGroups.count == 1)
        #expect(ClaudeHookInstaller.isInstalled(in: merged))
    }

    // MARK: - File level

    func tempSettingsURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tb-hooks-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    @Test("install creates the settings file when missing and is idempotent on disk")
    func installOnMissingFile() throws {
        let url = tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try ClaudeHookInstaller.install(at: url)
        #expect(first == true)
        #expect(ClaudeHookInstaller.isInstalled(at: url))
        let second = try ClaudeHookInstaller.install(at: url)
        #expect(second == false)   // second run: no-op
    }

    @Test("install preserves unrelated keys in an existing settings file")
    func installPreservesFile() throws {
        let url = tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"opus","permissions":{"allow":["Bash(ls:*)"]}}"#
            .write(to: url, atomically: true, encoding: .utf8)

        let installed = try ClaudeHookInstaller.install(at: url)
        #expect(installed == true)
        let data = try Data(contentsOf: url)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "opus")
        #expect((json["permissions"] as? [String: Any]) != nil)
        #expect(ClaudeHookInstaller.isInstalled(in: json))
    }

    @Test("a malformed settings file throws and is left untouched")
    func malformedFileUntouched() throws {
        let url = tempSettingsURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = "{not json"
        try garbage.write(to: url, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) { try ClaudeHookInstaller.install(at: url) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents == garbage)
    }
}
