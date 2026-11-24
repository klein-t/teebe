import AppKit
import Observation
import QuartzCore
import SwiftUI
import TeebeCore

/// Moves the menu bar orbs with Core Animation. Each moving orb is a small layer
/// on the status button, filled with the menu bar's ink and masked by one cycle
/// of pre-rendered frames that a repeating keyframe animation steps through. The
/// render server plays it; teebe does no work per frame. The title image the
/// button shows leaves those orbs out, so nothing is drawn twice.
///
/// Motion runs only while an orb moves and the item can be seen: not with the
/// option off or Reduce Motion, nor while the screen sleeps, the session is
/// locked or the item is covered.
@MainActor
@Observable
final class AgentMenuBarAnimator {
    static let shared = AgentMenuBarAnimator()
    /// As fine as the rows' orbs (`ThinkingOrbClock.framesPerSecond`).
    static let framesPerSecond: Double = 30

    struct Request: Equatable {
        let title: AgentMenuBarTitle
        let animates: Bool
    }

    /// The orbs Core Animation draws now; the title image leaves them out.
    private(set) var movingOrbs: Set<AgentMenuBarAnimation.Orb> = []

    @ObservationIgnored private var request: Request?
    @ObservationIgnored private var screenAsleep = false
    @ObservationIgnored private var sessionLocked = false
    @ObservationIgnored private var observing = false
    @ObservationIgnored private weak var button: NSStatusBarButton?
    @ObservationIgnored private var overlay: OrbOverlayView?
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    /// Frames by orb and backing scale, drawn once.
    @ObservationIgnored private var frames: [FrameKey: [CGImage]] = [:]

    private struct FrameKey: Hashable {
        let orb: AgentMenuBarAnimation.Orb
        let scale: CGFloat
    }

    func configure(title: AgentMenuBarTitle, animates: Bool) {
        request = Request(title: title, animates: animates)
        startObserving()
        update()
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func update() {
        guard let request, let button = statusButton() else { return stop() }
        let orbs = AgentMenuBarAnimation.animated(request.title, animates: request.animates, reduceMotion: reduceMotion)
        let visible = button.window?.occlusionState.contains(.visible) ?? true
        guard AgentMenuBarAnimation.timerRuns(orbs, screenAsleep: screenAsleep, sessionLocked: sessionLocked,
                                              itemVisible: visible) else { return stop() }
        // A status item put back after being hidden has a new button.
        let overlay = self.overlay.flatMap { $0.superview === button ? $0 : nil } ?? makeOverlay(on: button)
        overlay.show(AgentMenuBarImage.Layout(request.title), moving: orbs, in: button) { orb, scale in
            self.frames(orb, scale: scale)
        }
        if movingOrbs != orbs { movingOrbs = orbs }
    }

    /// No motion: the overlay goes and the title image draws every orb still.
    private func stop() {
        overlay?.clear()
        if !movingOrbs.isEmpty { movingOrbs = [] }
    }

    private func frames(_ orb: AgentMenuBarAnimation.Orb, scale: CGFloat) -> [CGImage] {
        let key = FrameKey(orb: orb, scale: scale)
        if let cached = frames[key] { return cached }
        let made = AgentMenuBarImage.orbFrames(orb.state, framesPerSecond: Self.framesPerSecond, scale: scale)
        frames[key] = made
        return made
    }

    private func makeOverlay(on button: NSStatusBarButton) -> OrbOverlayView {
        self.overlay?.removeFromSuperview()
        let overlay = OrbOverlayView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        button.addSubview(overlay)
        self.overlay = overlay
        // The ink follows the menu bar's appearance, as a template image would.
        appearanceObservation = button.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { AgentMenuBarAnimator.shared.overlay?.updateInk() }
        }
        return overlay
    }

    private func statusButton() -> NSStatusBarButton? {
        if let button, button.window != nil { return button }
        button = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBar") }
            .lazy.compactMap { Self.findButton(in: $0.contentView) }.first
        return button
    }

    private static func findButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { findButton(in: $0) }.first
    }

    private func startObserving() {
        guard !observing else { return }
        observing = true
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screenAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screenAsleep = false }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { _ in }
        observe(.default, NSWindow.didChangeOcclusionStateNotification) { _ in }
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.sessionLocked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.sessionLocked = false }
    }

    /// On `name`, apply `change` and decide again whether the orbs move.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         change: @escaping @MainActor (AgentMenuBarAnimator) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                change(AgentMenuBarAnimator.shared)
                AgentMenuBarAnimator.shared.update()
            }
        }
    }
}

/// The moving orbs, laid over the status button where its title image leaves
/// them out. Invisible to clicks, so the item works as before.
///
/// The button changes width with its title (one count or two), after the new
/// title is known. The orbs are placed again whenever this view is resized with
/// it, so they never keep the position they had in the old width.
@MainActor
final class OrbOverlayView: NSView {
    private(set) var orbLayers: [AgentMenuBarAnimation.Orb: CALayer] = [:]
    private var built: Built?
    private var layout: AgentMenuBarImage.Layout?

    /// What the layers were last built for. Where they sit is `place`'s job.
    private struct Built: Equatable {
        let moving: Set<AgentMenuBarAnimation.Orb>
        let scale: CGFloat
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    func show(_ layout: AgentMenuBarImage.Layout, moving: Set<AgentMenuBarAnimation.Orb>, in button: NSView,
              frames: (AgentMenuBarAnimation.Orb, CGFloat) -> [CGImage]) {
        guard let layer else { return }
        if frame != button.bounds { frame = button.bounds }
        let scale = button.window?.backingScaleFactor ?? 2
        let wanted = Built(moving: moving, scale: scale)
        if built != wanted {
            clear()
            built = wanted
            for piece in layout.pieces where moving.contains(piece.orb) {
                let images = frames(piece.orb, scale)
                guard let first = images.first else { continue }
                let ink = CALayer()
                ink.bounds = NSRect(origin: .zero, size: piece.orbRect.size)
                ink.anchorPoint = .zero
                ink.contentsScale = scale
                let mask = CALayer()
                mask.frame = ink.bounds
                mask.contentsScale = scale
                mask.contents = first
                ink.mask = mask
                let animation = CAKeyframeAnimation(keyPath: "contents")
                animation.values = images
                animation.calculationMode = .discrete
                animation.duration = AgentMenuBarImage.cycle(piece.orb.state)
                animation.repeatCount = .infinity
                animation.isRemovedOnCompletion = false
                mask.add(animation, forKey: "orb")
                layer.addSublayer(ink)
                orbLayers[piece.orb] = ink
            }
            updateInk()
        }
        self.layout = layout
        place()
    }

    /// Where an orb of `layout` sits in a button of `size`, y up: the title image
    /// is centered in the button, like any status item image.
    static func orbOrigin(_ piece: AgentMenuBarPiece, of layout: AgentMenuBarImage.Layout, in size: NSSize) -> NSPoint {
        let origin = NSPoint(x: ((size.width - layout.size.width) / 2).rounded(),
                             y: ((size.height - layout.size.height) / 2).rounded())
        // Layout is y down; this view is y up.
        return NSPoint(x: origin.x + piece.orbRect.minX, y: origin.y + layout.size.height - piece.orbRect.maxY)
    }

    /// Move the orbs to where the title image leaves room for them, in the size
    /// this view has now. The layers stay, so the motion does not start over.
    private func place() {
        guard let layout else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for piece in layout.pieces {
            orbLayers[piece.orb]?.position = Self.orbOrigin(piece, of: layout, in: bounds.size)
        }
        CATransaction.commit()
    }

    func clear() {
        orbLayers.values.forEach { $0.removeFromSuperlayer() }
        orbLayers = [:]
        built = nil
        layout = nil
    }

    /// The label color as the menu bar shows it: dark on a light bar, light on a dark one.
    func updateInk() {
        var ink = NSColor.labelColor.cgColor
        (superview ?? self).effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbLayers.values.forEach { $0.backgroundColor = ink }
        CATransaction.commit()
    }
}
