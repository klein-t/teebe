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
        let overlay = self.overlay ?? makeOverlay(on: button)
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
@MainActor
final class OrbOverlayView: NSView {
    private var orbLayers: [AgentMenuBarAnimation.Orb: CALayer] = [:]
    private var shown: Shown?

    /// What the layers were last built for.
    private struct Shown: Equatable {
        let rects: [NSRect]
        let moving: Set<AgentMenuBarAnimation.Orb>
        let scale: CGFloat
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ layout: AgentMenuBarImage.Layout, moving: Set<AgentMenuBarAnimation.Orb>, in button: NSStatusBarButton,
              frames: (AgentMenuBarAnimation.Orb, CGFloat) -> [CGImage]) {
        guard let layer else { return }
        let scale = button.window?.backingScaleFactor ?? 2
        // The title image is centered in the button, like any status item image.
        let origin = NSPoint(x: ((bounds.width - layout.size.width) / 2).rounded(),
                             y: ((bounds.height - layout.size.height) / 2).rounded())
        let rects = layout.pieces.map { piece -> NSRect in
            // Layout is y down; this view is y up.
            NSRect(x: origin.x + piece.orbRect.minX, y: origin.y + layout.size.height - piece.orbRect.maxY,
                   width: piece.orbRect.width, height: piece.orbRect.height)
        }
        let wanted = Shown(rects: rects, moving: moving, scale: scale)
        guard shown != wanted else { return }
        clear()
        shown = wanted
        for (piece, rect) in zip(layout.pieces, rects) where moving.contains(piece.orb) {
            let images = frames(piece.orb, scale)
            guard let first = images.first else { continue }
            let ink = CALayer()
            ink.frame = rect
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

    func clear() {
        orbLayers.values.forEach { $0.removeFromSuperlayer() }
        orbLayers = [:]
        shown = nil
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
