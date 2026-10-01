import SwiftUI
import AppKit

/// The main window's background: a translucent glass that picks up the desktop
/// behind the window, the way Finder does. It is near-white in light mode and a
/// deep grey in dark mode, and follows live appearance changes on its own.
struct WindowBackdrop: View {
    var body: some View {
        BehindWindowGlass().ignoresSafeArea()
    }
}

/// A behind-window vibrancy layer. It blurs what is behind the window, never the
/// window's own content, so the same glass can sit under content that scrolls
/// beneath it (the pinned folder rows) and still match the window around it.
/// With Reduce Transparency, AppKit renders it solid on its own.
struct BehindWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        // Near-white in light mode, deep grey in dark; the sidebar material is
        // grayer in light and lets more of the desktop's color through in dark.
        view.material = .headerView
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
