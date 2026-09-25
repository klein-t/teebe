import AppKit
import SwiftUI

/// Explanatory help uses one hover-only surface: a short sentence, no repeated
/// heading, immediate highlight, delayed appearance, and no click action.
/// Controls with their own hover chrome pass `highlight: false`.
enum HelpStyle {
    static let delay: Duration = .milliseconds(350)
    static let horizontalPadding: CGFloat = 10
    static let verticalPadding: CGFloat = 7
    static let maximumWidth: CGFloat = 300
    static let cornerRadius: CGFloat = 7
}

/// Informational glyph, deliberately not a button: clicking never opens a
/// second surface or changes the adjacent setting. The text remains accessible.
struct HelpInfo: View {
    let title: String
    let explanation: String

    var body: some View {
        Image(systemName: "info.circle")
            .font(Typography.body)
            .foregroundStyle(.secondary)
            .frame(width: 22, height: 22)
            .hoverHelp(explanation)
            .accessibilityLabel("About \(title.lowercased())")
    }
}

extension View {
    /// A short, app-local delay without changing macOS tooltip preferences.
    func hoverHelp(_ text: String, highlight: Bool = true) -> some View {
        background(HoverHelpAnchor(text: text, highlight: highlight))
            .accessibilityHint(text)
    }

    /// The same surface with rich content: shown after the same delay, but at the
    /// card's own size and starting at the view's leading edge. `summary` is the
    /// plain-text version, for accessibility and to notice when the card changes.
    func hoverCard<Card: View>(_ summary: String, @ViewBuilder card: () -> Card) -> some View {
        background(HoverHelpAnchor(text: summary, highlight: false, card: AnyView(card())))
            .accessibilityHint(summary)
    }
}

private struct HoverHelpAnchor: NSViewRepresentable {
    let text: String
    let highlight: Bool
    var card: AnyView?
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HoverHelpView { HoverHelpView() }

    func updateNSView(_ view: HoverHelpView, context: Context) {
        if view.text != text || view.enabled != isEnabled {
            HoverHelpPresenter.shared.dismiss(owner: view)
        }
        view.text = text
        view.card = card
        view.enabled = isEnabled
        view.showsHighlight = highlight
        if !isEnabled { view.highlighted = false }
    }

    static func dismantleNSView(_ view: HoverHelpView, coordinator: ()) {
        HoverHelpPresenter.shared.dismiss(owner: view)
    }
}

final class HoverHelpView: NSView {
    var text = ""
    /// Rich content shown instead of `text` (see `hoverCard`).
    var card: AnyView?
    var enabled = true
    var showsHighlight = true
    var highlighted = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted, enabled, showsHighlight else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

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
        highlighted = true
        HoverHelpPresenter.shared.schedule(owner: self)
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = false
        HoverHelpPresenter.shared.dismiss(owner: self)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        highlighted = false
        HoverHelpPresenter.shared.dismiss(owner: self)
        super.viewWillMove(toWindow: newWindow)
    }
}

/// One non-interactive panel, outside SwiftUI layout: never steals focus or
/// participates in the main window's size calculations.
@MainActor
final class HoverHelpPresenter {
    static let shared = HoverHelpPresenter()
    static let delay = HelpStyle.delay
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

    /// Below the anchor (above when there is no room), centred on it, or starting
    /// `leadingInset` in from its leading edge.
    static func frame(size: NSSize, anchor: NSRect, screen: NSRect, leadingInset: CGFloat? = nil) -> NSRect {
        let preferredX = leadingInset.map { anchor.minX + $0 } ?? anchor.midX - size.width / 2
        let x = min(max(preferredX, screen.minX + 6), screen.maxX - size.width - 6)
        let below = anchor.minY - size.height - 6
        let y = below >= screen.minY + 6 ? below : min(anchor.maxY + 6, screen.maxY - size.height - 6)
        return NSRect(origin: NSPoint(x: x, y: max(screen.minY + 6, y)), size: size)
    }

    func show(owner: HoverHelpView, window: NSWindow) {
        let root = owner.card.map { AnyView($0.fixedSize(horizontal: false, vertical: true)) } ?? AnyView(
            Text(owner.text)
                .font(Typography.body)
                .foregroundStyle(.primary)
                .padding(.horizontal, HelpStyle.horizontalPadding).padding(.vertical, HelpStyle.verticalPadding)
                .frame(maxWidth: HelpStyle.maximumWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: HelpStyle.cornerRadius))
        )
        let content = NSHostingView(rootView: root)
        let size = content.fittingSize
        // A tooltip has a measured, fixed size. NSHostingView's automatic window
        // sizing can otherwise grow the panel after orderFront, moving its bottom
        // hundreds of points away from the anchor.
        content.sizingOptions = []
        content.frame = NSRect(origin: .zero, size: size)
        let anchor = window.convertToScreen(owner.convert(owner.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? anchor
        let frame = Self.frame(size: size, anchor: anchor, screen: screen, leadingInset: owner.card == nil ? nil : 0)
        let popup = NSPanel(contentRect: frame,
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.ignoresMouseEvents = true
        popup.level = .popUpMenu
        popup.hidesOnDeactivate = true
        popup.contentView = content
        popup.setFrame(frame, display: false)
        popup.orderFront(nil)
        // The shadow follows the content's rounded corners once it has drawn.
        popup.invalidateShadow()
        panel = popup
    }
}
