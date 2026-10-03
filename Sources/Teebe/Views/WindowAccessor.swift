import SwiftUI
import AppKit

/// Bridges to the hosting `NSWindow` so the main window can float on top (PRD §5.1,
/// TECH_SPEC §7.1).
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Like `WindowAccessor`, but also keeps the float level in sync and reports when
/// the user finishes dragging the window's edge (so the new height can be
/// remembered). Programmatic `setFrame` calls do not fire `didEndLiveResize`, so
/// our own resizing never feeds back here.
struct WindowController: NSViewRepresentable {
    var floatOnTop: Bool
    var onResolve: (NSWindow) -> Void
    var onLiveResizeStart: () -> Void
    var onLiveResizeEnd: (CGFloat) -> Void
    /// Green "zoom" button (and double-click on the title bar is left to AppKit). We
    /// override it to grow the window to full height at the same width instead of the
    /// default fill-the-screen zoom.
    var onZoom: () -> Void
    /// The window moved or changed screen: how much room is left below its top edge
    /// changed, and SwiftUI observes neither.
    var onGeometryChange: () -> Void
    /// The window's height changed — ours or AppKit's. AppKit grows a window on its
    /// own (a constraint pass, a restored frame), and SwiftUI clears the maximum
    /// height we set after every layout, so this is the only place that notices.
    var onWindowResized: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.refresh(parent: self)
        DispatchQueue.main.async { context.coordinator.attach(view.window, parent: self) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Cheap, synchronous: just freshen the stored closures / float level.
        // Only schedule the one-time attach if the window isn't resolved yet —
        // re-dispatching every frame is what made live resize lag.
        context.coordinator.refresh(parent: self)
        if context.coordinator.window == nil {
            DispatchQueue.main.async { context.coordinator.attach(nsView.window, parent: self) }
        }
    }

    final class Coordinator: NSObject {
        private(set) weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []
        private var floatOnTop = false
        private var onLiveResizeStart: (() -> Void)?
        private var onLiveResizeEnd: ((CGFloat) -> Void)?
        private var onZoom: (() -> Void)?
        private var onGeometryChange: (() -> Void)?
        private var onWindowResized: (() -> Void)?

        /// Per-update, no allocation: refresh the callbacks and float level only.
        func refresh(parent: WindowController) {
            onLiveResizeStart = parent.onLiveResizeStart
            onLiveResizeEnd = parent.onLiveResizeEnd
            onZoom = parent.onZoom
            onGeometryChange = parent.onGeometryChange
            onWindowResized = parent.onWindowResized
            if floatOnTop != parent.floatOnTop {
                floatOnTop = parent.floatOnTop
                applyLevel()
            }
        }

        @objc private func zoomClicked() { onZoom?() }

        private func applyLevel() {
            window?.level = floatOnTop && !NSApp.isActive ? .floating : .normal
        }

        /// One-time: bind to the window and install the live-resize observers.
        func attach(_ window: NSWindow?, parent: WindowController) {
            guard let window, self.window == nil else { return }
            self.window = window
            floatOnTop = parent.floatOnTop
            applyLevel()
            parent.onResolve(window)
            // Pinned windows only need to float while another app is in front. Keeping
            // them at the normal level while teebe is active means App Exposé and
            // Mission Control still list them (floating-level windows are skipped).
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] _ in self?.applyLevel() })
            }
            // Take over the green zoom button so it grows to full height, not full screen.
            if let zoomButton = window.standardWindowButton(.zoomButton) {
                zoomButton.target = self
                zoomButton.action = #selector(zoomClicked)
            }
            // Re-assert the height clamp the instant a drag begins (SwiftUI's
            // windowResizability keeps re-enabling free resize otherwise)…
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onLiveResizeStart?() })
            // A window dragged down the screen (or onto a shorter one) has less room
            // below its top edge, which is what the section clamps are measured against.
            for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.onGeometryChange?() })
            }
            // Every height change, whoever made it: the window is only ever as tall as
            // the layout asks for, so a size we didn't ask for has to be noticed.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in self?.onWindowResized?() })
            // …and remember the new height once the user lets go.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                guard let window else { return }
                self?.onLiveResizeEnd?(window.frame.height)
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
