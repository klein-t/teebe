import Foundation
import Sparkle
import Testing
@testable import Teebe

@MainActor
@Suite("Update settings")
struct UpdaterSettingsTests {
    @MainActor
    final class Rig {
        let directory: URL
        let domain = "dev.teebe.tests.updater.\(UUID().uuidString)"
        let bundle: Bundle
        let defaults: UserDefaults

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString).bundle")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let info: [String: Any] = [
                "CFBundleIdentifier": domain,
                "CFBundleVersion": "1",
                "CFBundleName": "Teebe Update Test",
                "SUEnableAutomaticChecks": true,
                "SUFeedURL": "http://127.0.0.1:9/appcast.xml",
                "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString()
            ]
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: directory.appendingPathComponent("Info.plist"))
            bundle = try #require(Bundle(url: directory))
            defaults = try #require(UserDefaults(suiteName: domain))
        }

        func makeUpdater() -> SPUUpdater {
            // Never start the updater: tests must not send requests or show prompts.
            SPUUpdater(
                hostBundle: bundle,
                applicationBundle: bundle,
                userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil),
                delegate: nil
            )
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("turning checks off and on persists across updater recreation")
    func preferencePersists() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let model = UpdaterController(updater: rig.makeUpdater())
        #expect(model.automaticallyChecksForUpdates)

        model.setAutomaticallyChecksForUpdates(false)
        #expect(!model.automaticallyChecksForUpdates)
        #expect(!rig.defaults.bool(forKey: "SUEnableAutomaticChecks"))
        let reopened = UpdaterController(updater: rig.makeUpdater())
        #expect(!reopened.automaticallyChecksForUpdates)

        reopened.setAutomaticallyChecksForUpdates(true)
        #expect(reopened.automaticallyChecksForUpdates)
        #expect(rig.defaults.bool(forKey: "SUEnableAutomaticChecks"))
        #expect(UpdaterController(updater: rig.makeUpdater()).automaticallyChecksForUpdates)
    }

    @Test("existing opt-out is preserved and Sparkle changes are reflected")
    func observesSparklePreference() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let updater = rig.makeUpdater()
        let model = UpdaterController(updater: updater)
        #expect(!model.automaticallyChecksForUpdates)

        updater.automaticallyChecksForUpdates = true
        #expect(model.automaticallyChecksForUpdates)
        updater.automaticallyChecksForUpdates = false
        #expect(!model.automaticallyChecksForUpdates)
    }

    @Test("manual checks remain available when automatic checks are off")
    func manualChecksRemainAvailable() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        rig.defaults.set(false, forKey: "SUEnableAutomaticChecks")
        let updater = rig.makeUpdater()
        let model = UpdaterController(updater: updater)
        try updater.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!model.automaticallyChecksForUpdates)
        #expect(model.canCheckForUpdates)
        #expect(updater.lastUpdateCheckDate == nil)
    }

}
