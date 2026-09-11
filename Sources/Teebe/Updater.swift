import SwiftUI
import Sparkle

/// Wraps Sparkle's standard updater so the app can check for and install updates
/// in place (appcast + EdDSA-signed deltas). The updater reads `SUFeedURL` and
/// `SUPublicEDKey` from the bundle's `Info.plist` (see `scripts/make-app.sh`).
///
/// `startingUpdater: true` lets Sparkle schedule its own background checks per
/// the user's preference; the menu command below drives a manual check.
@MainActor
final class UpdaterController: ObservableObject {
    private var controller: SPUStandardUpdaterController?
    private let updater: SPUUpdater

    /// Mirrors `canCheckForUpdates` so the menu item disables itself while a
    /// check is already in flight.
    @Published var canCheckForUpdates = false

    @Published private(set) var automaticallyChecksForUpdates = false

    convenience init() {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.init(updater: controller.updater)
        self.controller = controller
    }

    init(updater: SPUUpdater) {
        self.updater = updater
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .assign(to: &$automaticallyChecksForUpdates)
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Sparkle persists this choice and resets its background check schedule.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        updater.checkForUpdates()
    }
}

/// "Check for Updates…" item in the app menu, wired to the shared updater.
struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
