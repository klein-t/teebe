// Drawing for the thinking-orbs port (thinking-orbs 0.3.2, MIT License,
// Copyright (c) 2026 Jakub Antalik; see THIRD-PARTY-LICENSES.md). The geometry
// lives in TeebeCore's ThinkingOrbStyle; this view only paints its frames.

import AppKit
import QuartzCore
import SwiftUI
import TeebeCore

/// A 20 pt animated dotted orb: `.solving` for an agent at work, `.breathing`
/// for one waiting on the user.
///
/// The caller picks the ink and says whether the substrate is dark (dark app
/// appearance or a selected, accent-filled row); the orb keeps the package's
/// depth shading, fading the ink toward black on dark substrates and toward
/// white on light ones. `scale` shrinks the drawing inside the 20 pt slot.
///
/// Cost control: the frames are drawn by a plain AppKit view on its own display
/// link, so an animating orb never touches the SwiftUI view graph (a
/// `TimelineView` re-ran SwiftUI's update pass for the whole window every frame).
/// Frames are capped at 30 fps and every instance reads one clock (wall time),
/// so several orbs stay in phase. Reduce Motion shows the package's static
/// representative frame. The link stops while `paused` (low-power mode, the
/// occluded window), while the orb's own window is occluded, and skips frames
/// while the orb is scrolled out of sight.
struct ThinkingOrbView: NSViewRepresentable {
    var state: ThinkingOrbState
    var ink: Color
    var isDark: Bool
    var scale: Double = 1
    var paused = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> ThinkingOrbNSView { ThinkingOrbNSView() }

    func updateNSView(_ view: ThinkingOrbNSView, context: Context) {
        view.configure(ThinkingOrbNSView.Configuration(
            state: state, tint: ThinkingOrbNSView.rgb(ink), isDark: isDark, scale: scale,
            animates: !reduceMotion, paused: paused))
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThinkingOrbNSView, context: Context) -> CGSize? {
        CGSize(width: ThinkingOrbStyle.size, height: ThinkingOrbStyle.size)
    }

    static func dismantleNSView(_ view: ThinkingOrbNSView, coordinator: ()) {
        view.stopClock()
    }
}

/// When an orb's display link should be ticking. Pure, so the rule is testable.
enum ThinkingOrbClock {
    /// 30 fps: at 20 pt the dots move well under a point per frame, so a higher
    /// rate buys nothing visible while several orbs may run at once.
    static let framesPerSecond: Float = 30

    static func runs(animates: Bool, paused: Bool, inWindow: Bool, windowVisible: Bool) -> Bool {
        animates && !paused && inWindow && windowVisible
    }
}

/// The AppKit view that paints one orb. See `ThinkingOrbView`.
final class ThinkingOrbNSView: NSView {
    struct Configuration: Equatable {
        var state: ThinkingOrbState
        var tint: ThinkingOrbRGB
        var isDark: Bool
        var scale: Double
        var animates: Bool
        var paused: Bool
    }

    private var configuration = Configuration(state: .solving, tint: ThinkingOrbRGB(red: 0, green: 0, blue: 0),
                                              isDark: false, scale: 1, animates: true, paused: false)
    private var style = ThinkingOrbStyle(state: .solving)
    /// Retains this view until invalidated, which leaving the window does.
    private var link: CADisplayLink?
    private var occlusionObserver: NSObjectProtocol?
    private var dotLayers: [CALayer] = []
    private var colors: [Int: CGColor] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Each dot is a small round sublayer that a frame only moves and recolours,
    /// so Core Animation rasterises the dots, not this process. Drawing them with
    /// Core Graphics cost several times more per frame: anti-aliased ellipse
    /// paths and, through AppKit's drawing path, a per-dot colour conversion into
    /// a wide-colour backing store.
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: ThinkingOrbStyle.size, height: ThinkingOrbStyle.size) }
    /// Clicks and hovers belong to the row around the orb.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(_ new: Configuration) {
        guard new != configuration else { return }
        if new.state != configuration.state { style = ThinkingOrbStyle(state: new.state) }
        if new.tint != configuration.tint || new.isDark != configuration.isDark { colors.removeAll() }
        configuration = new
        needsDisplay = true
        updateClock()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        colors.removeAll()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateClock() }
            }
        }
        updateClock()
    }

    func stopClock() {
        link?.invalidate()
        link = nil
    }

    private func updateClock() {
        let runs = ThinkingOrbClock.runs(animates: configuration.animates, paused: configuration.paused,
                                         inWindow: window != nil,
                                         windowVisible: window?.occlusionState.contains(.visible) ?? false)
        guard runs else { stopClock(); needsDisplay = true; return }
        guard link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick))
        let fps = ThinkingOrbClock.framesPerSecond
        link.preferredFrameRateRange = CAFrameRateRange(minimum: fps / 2, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // Scrolled out of the list's viewport: nothing to show, nothing to draw.
        guard !visibleRect.isEmpty else { return }
        needsDisplay = true
    }

    override func updateLayer() {
        guard let host = layer else { return }
        let time = configuration.animates
            ? Date().timeIntervalSinceReferenceDate * style.speed : ThinkingOrbStyle.staticTime
        let dots = style.frame(at: time)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        while dotLayers.count < dots.count {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: Self.unitRadius * 2, height: Self.unitRadius * 2)
            dot.cornerRadius = Self.unitRadius
            host.addSublayer(dot)
            dotLayers.append(dot)
        }
        // Dots come sorted far to near; later sublayers draw on top. The ported
        // coordinates are y-down, like SwiftUI's canvas; this layer is y-up.
        let scale = configuration.scale
        let origin = CGPoint(x: bounds.midX - ThinkingOrbStyle.size / 2 * scale,
                             y: bounds.midY + ThinkingOrbStyle.size / 2 * scale)
        for (index, dot) in dots.enumerated() {
            let sublayer = dotLayers[index]
            let size = dot.radius * scale / Self.unitRadius
            sublayer.isHidden = false
            sublayer.transform = CATransform3DMakeScale(size, size, 1)
            sublayer.position = CGPoint(x: origin.x + dot.x * scale, y: origin.y - dot.y * scale)
            sublayer.backgroundColor = color(configuration.tint.shaded(white: dot.white, dark: configuration.isDark))
            sublayer.opacity = Float(dot.alpha)
        }
        for sublayer in dotLayers.dropFirst(dots.count) { sublayer.isHidden = true }
        CATransaction.commit()
    }

    /// Dots are one round layer each, sized by a scale transform: one property
    /// per frame instead of bounds and corner radius.
    private static let unitRadius: CGFloat = 4
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Shades are whole sRGB channels, so a handful of colours repeat every frame.
    /// Each is converted once into the window's colour space, which Core
    /// Animation would otherwise do for every dot of every frame.
    private func color(_ shade: ThinkingOrbRGB) -> CGColor? {
        let key = Int(shade.red) << 16 | Int(shade.green) << 8 | Int(shade.blue)
        if let cached = colors[key] { return cached }
        let components: [CGFloat] = [shade.red / 255, shade.green / 255, shade.blue / 255, 1]
        let srgb = CGColor(colorSpace: Self.sRGB, components: components)
        let made = window?.colorSpace?.cgColorSpace.flatMap {
            srgb?.converted(to: $0, intent: .defaultIntent, options: nil)
        } ?? srgb
        colors[key] = made
        return made
    }

    /// The ink as whole 0...255 sRGB channels, as the JS tint parser yields.
    static func rgb(_ color: Color) -> ThinkingOrbRGB {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func channel(_ c: CGFloat) -> Double { (Double(c) * 255).rounded() }
        return ThinkingOrbRGB(red: channel(srgb.redComponent), green: channel(srgb.greenComponent),
                              blue: channel(srgb.blueComponent))
    }
}
