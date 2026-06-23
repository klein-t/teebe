import SwiftUI
import AppKit
import TeebeCore

/// Makes the process a regular foreground GUI app even when launched as a bare
/// SPM executable (`swift run`) rather than from a `.app` bundle — otherwise the
/// window never appears (no activation policy → background process).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let logo = Brand.logo { NSApp.applicationIconImage = logo }   // Dock / app-switcher icon
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// App entry point. This shell wires the view models to a minimal, functional
/// UI so the app builds and runs.
@main
struct TeebeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    @State private var preview: PreviewModel
    @StateObject private var updater = UpdaterController()

    init() {
        // One shared environment, constructed exactly once.
        let environment = AppEnvironment.live()
        _app = State(initialValue: AppModel(environment: environment))
        _preview = State(initialValue: PreviewModel(environment: environment))
    }

    var body: some Scene {
        WindowGroup(Brand.name) {
            RootView(app: app, preview: preview)
                .task { await app.bootstrap() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize) // freely resizable; content scrolls inside
        .defaultSize(width: 440, height: 640)
        .commands {
            // Standard "Check for Updates…" item, placed in the app menu next to About.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
            }
        }

        // Separate floating Quick Look panel (D4 / PRD §5.2).
        Window("Quick Look", id: "preview") {
            PreviewPanel(preview: preview, app: app)
        }
        .windowResizability(.contentSize)
    }
}
