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
    /// A new `reveal` value shows the card straight away, without the pointer (the
    /// keyboard's way in); the next key, click or scroll puts it away. `onReveal`
    /// runs once it is shown, so the caller can spend the request.
    func hoverCard<Card: View>(_ summary: String, reveal: Int? = nil, onReveal: (() -> Void)? = nil,
                               @ViewBuilder card: () -> Card) -> some View {
        background(HoverHelpAnchor(text: summary, highlight: false, card: AnyView(card()), reveal: reveal,
                                   onReveal: onReveal))
            .accessibilityHint(summary)
    }
}

private struct HoverHelpAnchor: NSViewRepresentable {
    let text: String
    let highlight: Bool
    var card: AnyView?
    var reveal: Int?
    var onReveal: (() -> Void)?
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> HoverHelpView {
        let view = HoverHelpView()
        // A request already standing when this anchor is made was meant for an
        // earlier one (the row was redrawn, regrouped or swapped its mark): not new.
        view.revealed = reveal
        return view
    }

    func updateNSView(_ view: HoverHelpView, context: Context) {
        if view.text != text || view.enabled != isEnabled {
            HoverHelpPresenter.shared.dismiss(owner: view)
        }
        view.text = text
        view.card = card
        view.enabled = isEnabled
        view.showsHighlight = highlight
        if !isEnabled { view.highlighted = false }
        if let reveal, reveal != view.revealed {
            view.revealed = reveal
            // After this update: the panel measures the view in its window.
            DispatchQueue.main.async { [weak view, onReveal] in
                guard let view else { return }
                HoverHelpPresenter.shared.reveal(owner: view)
                onReveal?()
            }
        }
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
    /// The last `reveal` value acted on.
    var revealed: Int?
    var highlighted = false {
        didSet { needsDisplay = true }
    }
    private var hoverArea: NSTrackingArea?

    /// Always active, like system tooltips: a visible window reacts to the pointer
    /// even while another app is frontmost.
    static let trackingOptions: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways, .inVisibleRect]

    // AppKit can report visibleRect beyond bounds for an unclipped view. With
    // inVisibleRect tracking, that makes neighboring rows share one hover area.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard highlighted, enabled, showsHighlight else { return }
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows clipping and layout itself. Replacing an area
        // while its pointer is inside can lose the corresponding exit event.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: Self.trackingOptions, owner: self, userInfo: nil)
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
        watch(owner)
        pending = Task { [weak self, weak owner] in
            do { try await Task.sleep(for: Self.delay) } catch { return }
            guard let self, let owner, self.owner === owner, let window = owner.window else { return }
            let point = owner.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard Self.canShow(owner: owner, window: window, pointerInside: owner.visibleRect.contains(point),
                               buttonsDown: NSEvent.pressedMouseButtons != 0) else { self.dismiss(); return }
            self.show(owner: owner, window: window)
        }
    }

    /// Show `owner`'s help now, pointer or not, until the next key, click, scroll
    /// or window change.
    func reveal(owner: HoverHelpView) {
        guard owner.enabled, !owner.text.isEmpty, let window = owner.window, window.isVisible else { return }
        watch(owner)
        show(owner: owner, window: window)
    }

    /// Take over from any other help and put it away on the events that end it.
    private func watch(_ owner: HoverHelpView) {
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
    }

    /// Whether a pending help surface may appear. Deliberately ignores key and
    /// active state: an inactive but visible window shows help too.
    static func canShow(owner: HoverHelpView, window: NSWindow, pointerInside: Bool, buttonsDown: Bool) -> Bool {
        owner.enabled && window.isVisible && pointerInside && !buttonsDown
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
        // Help also shows over an inactive window, so it must not hide with the app.
        popup.hidesOnDeactivate = false
        popup.contentView = content
        popup.setFrame(frame, display: false)
        popup.orderFront(nil)
        // The shadow follows the content's rounded corners once it has drawn.
        popup.invalidateShadow()
        panel = popup
    }
}

extension View {
    /// `onHover` that also fires while the window is inactive. SwiftUI's own
    /// hover tracking only follows the pointer in the active app.
    func pointerHover(_ action: @escaping (Bool) -> Void) -> some View {
        background(PointerHoverAnchor(onHover: action))
    }
}

private struct PointerHoverAnchor: NSViewRepresentable {
    let onHover: (Bool) -> Void

    func makeNSView(context: Context) -> PointerHoverView { PointerHoverView() }

    func updateNSView(_ view: PointerHoverView, context: Context) {
        view.onHover = onHover
    }
}

/// Reports the pointer entering and leaving, whatever window or app is active.
/// Invisible to clicks.
final class PointerHoverView: NSView {
    static let trackingOptions = HoverHelpView.trackingOptions
    var onHover: (Bool) -> Void = { _ in }
    private var hoverArea: NSTrackingArea?

    // AppKit can report visibleRect beyond bounds for an unclipped view. With
    // inVisibleRect tracking, that makes neighboring rows share one hover area.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // inVisibleRect follows clipping and layout itself. Replacing an area
        // while its pointer is inside can lose the corresponding exit event.
        guard hoverArea == nil else { return }
        let area = NSTrackingArea(rect: .zero, options: Self.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    // Forward every event. A separate native hover flag can get reset when
    // SwiftUI reparents the anchor while the row's own state remains alive.
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
