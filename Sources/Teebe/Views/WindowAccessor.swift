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

        /// Per-update, no allocation: refresh the callbacks and float level only.
        func refresh(parent: WindowController) {
            onLiveResizeStart = parent.onLiveResizeStart
            onLiveResizeEnd = parent.onLiveResizeEnd
            onZoom = parent.onZoom
            if floatOnTop != parent.floatOnTop {
                floatOnTop = parent.floatOnTop
                window?.level = floatOnTop ? .floating : .normal
            }
        }

        @objc private func zoomClicked() { onZoom?() }

        /// One-time: bind to the window and install the live-resize observers.
        func attach(_ window: NSWindow?, parent: WindowController) {
            guard let window, self.window == nil else { return }
            self.window = window
            floatOnTop = parent.floatOnTop
            window.level = floatOnTop ? .floating : .normal
            parent.onResolve(window)
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
