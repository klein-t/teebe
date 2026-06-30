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
        // Don't override `applicationIconImage`: that replaces the bundle's
        // `AppIcon.icns` (which macOS masks into the rounded squircle with depth)
        // with the raw full-bleed PNG, so the running app's Dock icon goes flat.
        // Leaving it unset lets the system icon render correctly while running too.
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
    @State private var whatsNew: WhatsNewModel
    @StateObject private var updater = UpdaterController()

    init() {
        // One shared environment, constructed exactly once.
        let environment = AppEnvironment.live()
        _app = State(initialValue: AppModel(environment: environment))
        _preview = State(initialValue: PreviewModel(environment: environment))
        _whatsNew = State(initialValue: WhatsNewModel(
            version: Brand.appVersion,
            changelogMarkdown: Brand.changelogMarkdown,
            store: environment.store
        ))
    }

    var body: some Scene {
        WindowGroup(Brand.name) {
            RootView(app: app, preview: preview)
                .task {
                    await app.bootstrap()
                    whatsNew.presentIfUpdated()   // greet once after an update
                }
                .sheet(isPresented: $whatsNew.isPresented) {
                    WhatsNewView(model: whatsNew)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize) // freely resizable; content scrolls inside
        .defaultSize(width: 440, height: 640)
        .commands {
            // "Check for Updates…" and "What's New" in the app menu next to About.
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
                Button("What's New in \(Brand.name)") { whatsNew.present() }
            }
        }

        // Separate floating Quick Look panel (D4 / PRD §5.2).
        Window("Quick Look", id: "preview") {
            PreviewPanel(preview: preview, app: app)
        }
        .windowResizability(.contentSize)
    }
}
