import AppKit
import SwiftUI

extension View {
    /// A short, app-local delay without changing macOS tooltip preferences.
    func hoverHelp(_ text: String) -> some View {
        background(HoverHelpAnchor(text: text))
            .accessibilityHint(text)
    }
}

private struct HoverHelpAnchor: NSViewRepresentable {
    let text: String
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HoverHelpView { HoverHelpView() }

    func updateNSView(_ view: HoverHelpView, context: Context) {
        if view.text != text || view.enabled != isEnabled {
            HoverHelpPresenter.shared.dismiss(owner: view)
        }
        view.text = text
        view.enabled = isEnabled
    }

    static func dismantleNSView(_ view: HoverHelpView, coordinator: ()) {
        HoverHelpPresenter.shared.dismiss(owner: view)
    }
}

final class HoverHelpView: NSView {
    var text = ""
    var enabled = true
    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard enabled, !text.isEmpty else { return }
        HoverHelpPresenter.shared.schedule(owner: self)
    }

    override func mouseExited(with event: NSEvent) {
        HoverHelpPresenter.shared.dismiss(owner: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        HoverHelpPresenter.shared.dismiss(owner: self)
        super.viewWillMove(toWindow: newWindow)
    }
}

/// One non-interactive panel, outside SwiftUI layout: never steals focus or
/// participates in the main window's size calculations.
@MainActor
final class HoverHelpPresenter {
    static let shared = HoverHelpPresenter()
    static let delay: Duration = .milliseconds(350)
    private(set) weak var owner: HoverHelpView?
    private var pending: Task<Void, Never>?
    private(set) var panel: NSPanel?
    private var eventMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    func schedule(owner: HoverHelpView) {
        dismiss()
        self.owner = owner
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown
        ]) { [weak self] event in
            self?.dismiss()
            return event
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.willCloseNotification,
                     NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: name == NSApplication.didResignActiveNotification ? NSApp : owner.window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            })
        }
        pending = Task { [weak self, weak owner] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard let self, let owner, self.owner === owner,
                  owner.enabled, let window = owner.window, window.isKeyWindow,
                  NSApp.isActive, NSEvent.pressedMouseButtons == 0 else { return }
            let point = owner.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard owner.visibleRect.contains(point) else { self.dismiss(); return }
            self.show(owner: owner, window: window)
        }
    }

    func dismiss(owner: HoverHelpView? = nil) {
        if let owner, self.owner !== owner { return }
        pending?.cancel()
        pending = nil
        panel?.orderOut(nil)
        panel = nil
        self.owner = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    static func frame(size: NSSize, anchor: NSRect, screen: NSRect) -> NSRect {
        let x = min(max(anchor.midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6)
        let below = anchor.minY - size.height - 6
        let y = below >= screen.minY + 6 ? below : min(anchor.maxY + 6, screen.maxY - size.height - 6)
        return NSRect(origin: NSPoint(x: x, y: max(screen.minY + 6, y)), size: size)
    }

    func show(owner: HoverHelpView, window: NSWindow) {
        let content = NSHostingView(rootView:
            Text(owner.text)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: 300)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        )
        let size = content.fittingSize
        let anchor = window.convertToScreen(owner.convert(owner.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        let popup = NSPanel(contentRect: Self.frame(size: size, anchor: anchor, screen: screen),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.ignoresMouseEvents = true
        popup.level = .popUpMenu
        popup.hidesOnDeactivate = true
        popup.contentView = content
        popup.orderFront(nil)
        panel = popup
    }
}
