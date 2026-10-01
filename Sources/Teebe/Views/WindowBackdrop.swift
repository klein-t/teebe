import SwiftUI
import AppKit

/// The main window's background. Light mode gets a translucent near-white that
/// picks up the desktop behind the window, the way Finder does; dark mode keeps
/// the material it always had.
struct WindowBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            BehindWindowGlass().ignoresSafeArea()
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }
}

/// A behind-window vibrancy layer. It blurs what is behind the window, never the
/// window's own content, so the same glass can sit under content that scrolls
/// beneath it (the pinned folder rows) and still match the window around it.
/// With Reduce Transparency, AppKit renders it solid on its own.
struct BehindWindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .headerView   // near-white, not the grayer sidebar material
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
