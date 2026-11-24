import SwiftUI
import AppKit
import TeebeCore

/// Makes the process a regular foreground GUI app even when launched as a bare
/// SPM executable (`swift run`) rather than from a `.app` bundle — otherwise the
/// window never appears (no activation policy → background process).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The saved Dock choice, applied before any window shows.
        NSApp.setActivationPolicy(DockPresence.savedShowsDockIcon() ? .regular : .accessory)
        AgentNotifier.showWhileFrontmost()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Don't override `applicationIconImage`: that replaces the bundle's
        // `AppIcon.icns` (which macOS masks into the rounded squircle with depth)
        // with the raw full-bleed PNG, so the running app's Dock icon goes flat.
        // Leaving it unset lets the system icon render correctly while running too.
        NSApp.activate(ignoringOtherApps: true)
        // Without a Dock icon, closing the last window would leave an invisible app
        // holding the keyboard: hand focus back to the app used before.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { note in
            guard let closing = note.object as? NSWindow, closing.canBecomeMain else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard DockPresence.isAccessory,
                          !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.canBecomeMain }) else { return }
                    NSApp.hide(nil)
                }
            }
        }
    }
    /// Quit when the main window goes away, but never while a regular window is
    /// still showing. Belt and braces for the pinned (floating-level) window, which
    /// window-tracking code tends to overlook (#105).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Without a Dock icon the app lives in the menu bar, window or not.
        guard !DockPresence.isAccessory else { return false }
        return !Self.hasVisibleWindow(in: sender.windows)
    }

    /// Opening teebe again (Finder, Spotlight, the Dock) brings its window back,
    /// also when it runs from the menu bar with its window closed.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowOpener.bringForward()
        return false
    }

    /// Without a Dock icon, launching teebe again only activates it, with no
    /// reopen event: bring the window back when it was closed.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard DockPresence.isAccessory, MainWindowOpener.mainWindow?.isVisible != true else { return }
        MainWindowOpener.bringForward()
    }

    /// True if any regular (non-panel) window is still on screen.
    static func hasVisibleWindow(in windows: [NSWindow]) -> Bool {
        hasVisibleWindow(windows.map { (visible: $0.isVisible, isPanel: $0 is NSPanel) })
    }

    /// Pure core of the check, so it can be tested without creating `NSWindow`s
    /// (which needs a running `NSApplication`).
    static func hasVisibleWindow(_ windows: [(visible: Bool, isPanel: Bool)]) -> Bool {
        windows.contains { $0.visible && !$0.isPanel }
    }
}

/// App entry point. This shell wires the view models to a minimal, functional
/// UI so the app builds and runs.
@main
struct TeebeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app: AppModel
    @State private var preview: PreviewModel
    @State private var whatsNew: WhatsNewModel
    @State private var agentOverview: AgentOverviewModel
    @StateObject private var updater = UpdaterController()

    init() {
        // One shared environment, constructed exactly once.
        let environment = AppEnvironment.live()
        let appModel = AppModel(environment: environment)
        _app = State(initialValue: appModel)
        let overview = AgentOverviewModel(app: appModel)
        overview.start()
        _agentOverview = State(initialValue: overview)
        _preview = State(initialValue: PreviewModel(environment: environment))
        _whatsNew = State(initialValue: WhatsNewModel(
            version: Brand.appVersion,
            changelogMarkdown: Brand.changelogMarkdown,
            store: environment.store
        ))
    }

    var body: some Scene {
        WindowGroup(Brand.name, id: WindowID.main) {
            RootWindowContent(app: app, preview: preview, whatsNew: whatsNew)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize) // freely resizable; content scrolls inside
        .defaultSize(width: 440, height: 640)
        .commands {
            // Custom About (adds website / GitHub / X links to the standard panel),
            // then "Check for Updates…", "What's New", and "Keyboard Shortcuts" below it.
            CommandGroup(replacing: .appInfo) { AboutMenuCommand() }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: updater)
                WhatsNewMenuCommand()
            }
            CommandGroup(after: .help) { KeyboardShortcutsMenuCommand() }
            MainWindowCommands()
        }

        // Separate floating Quick Look panel (D4 / PRD §5.2).
        Window("Preview Changes", id: "preview") {
            PreviewPanel(preview: preview, app: app)
        }
        .windowResizability(.contentSize)

        // "What's New" and the Keyboard Shortcuts cheat sheet are real, movable
        // windows rather than sheets (macOS pins sheets to the parent and won't let
        // you drag them). Chrome-less to match their in-content header; closed via the
        // footer button, Esc, or ⌘W.
        Window("What's New in \(Brand.name)", id: WindowID.whatsNew) {
            WhatsNewView(model: whatsNew)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            KeyboardShortcutsView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Agents working and waiting in every project, from the menu bar.
        MenuBarExtra(isInserted: Binding(get: { app.agentDisplay.showsMenuBarIcon },
                                         set: { app.agentDisplay.showsMenuBarIcon = $0 })) {
            AgentMenuBarMenu(overview: agentOverview, display: app.agentDisplay, app: app)
        } label: {
            AgentMenuBarLabel(overview: agentOverview, display: app.agentDisplay)
        }

        // Adds "Settings…" (⌘,) to the app menu.
        Settings {
            SettingsView(app: app, updater: updater)
        }
    }
}

/// Stable identifiers for the secondary windows opened via `openWindow(id:)`.
enum WindowID {
    static let main = "main"
    static let whatsNew = "whatsNew"
    static let shortcuts = "shortcuts"
}

/// Hosts the main window's content and, on the first launch after an update, opens
/// the What's New window. This lives in a `View` (not the `App` scene builder) so it
/// can read `openWindow` from the environment.
private struct RootWindowContent: View {
    let app: AppModel
    let preview: PreviewModel
    let whatsNew: WhatsNewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        RootView(app: app, preview: preview)
            .task {
                await app.bootstrap()
                app.setUpHookIfNeeded()            // one-time Claude Code hook offer
                if whatsNew.presentIfUpdated() {   // greet once after an update
                    openWindow(id: WindowID.whatsNew)
                }
            }
            // Covered window → low-power mode (stop FSEvents, ride the hook ping);
            // visible again → restart watchers and catch up.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didChangeOcclusionStateNotification
            )) { _ in
                app.setBackgrounded(!NSApp.occlusionState.contains(.visible))
            }
            // Coming back to the app is the moment its view of the remote is most
            // likely stale. Rate-limited and silent; see RemoteRefresher.
            .onReceive(NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )) { _ in
                Task { await app.refreshRemotes(force: false) }
            }
    }
}
