import AppKit
import SwiftUI
import TeebeCore

/// Shows or hides the Dock icon. Hidden, teebe runs as an accessory app: no Dock
/// tile, not in the app switcher, reached from its menu bar item.
@MainActor
enum DockPresence {
    static func apply(showsDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Switching policy can drop the app to the background; keep the window up.
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// The saved choice, read before any window shows so the Dock doesn't flash.
    static func savedShowsDockIcon(store: AppStateStore = AppStateStore()) -> Bool {
        let state = store.load()
        return AppPresence(showsMenuBarIcon: state.agentMenuBarIcon ?? true,
                           showsDockIcon: state.showDockIcon ?? true).showsDockIcon
    }

    static var isAccessory: Bool { NSApp.activationPolicy() == .accessory }
}

/// Opens the main window when none is left: in accessory mode closing it keeps
/// the app running, and the menu bar or a relaunch has to bring it back. Set by
/// a view that lives as long as the menu bar item, which can open windows.
@MainActor
enum MainWindowOpener {
    static var open: (() -> Void)?

    static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.title == Brand.name && $0.canBecomeMain }
    }

    /// Bring the main window forward and make it key, opening it if it was closed.
    static func bringForward() {
        // Closing the last window without a Dock icon hides the app; its windows
        // stay hidden, new ones too, until it is unhidden.
        if NSApp.isHidden { NSApp.unhide(nil) }
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            open?()
        }
    }
}
