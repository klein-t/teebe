// Drawing for the thinking-orbs port (thinking-orbs 0.3.2, MIT License,
// Copyright (c) 2026 Jakub Antalik; see THIRD-PARTY-LICENSES.md). The geometry
// lives in TeebeCore's ThinkingOrbStyle; this view only paints its frames.

import AppKit
import SwiftUI
import TeebeCore

/// A 20 pt animated dotted orb: `.solving` for an agent at work, `.breathing`
/// for one waiting on the user.
///
/// The caller picks the ink and says whether the substrate is dark (dark app
/// appearance or a selected, accent-filled row); the orb keeps the package's
/// depth shading, fading the ink toward black on dark substrates and toward
/// white on light ones.
///
/// Cost control: frames are capped at 30 fps and every instance shares one
/// clock (wall time), so several orbs stay in phase. Reduce Motion shows the
/// package's static representative frame. Pass `paused: true` while the app is
/// in low-power mode (`SelectorModel.isLowPower`, the occluded window) to stop
/// the timeline altogether.
struct ThinkingOrbView: View {
    var state: ThinkingOrbState
    var ink: Color
    var isDark: Bool
    var paused = false

    /// 30 fps: at 20 pt the dots move well under a point per frame, so a
    /// higher rate buys nothing visible while several orbs may run at once.
    static let frameInterval: TimeInterval = 1.0 / 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let style = ThinkingOrbStyle(state: state)
        Group {
            if reduceMotion {
                ThinkingOrbFrame(style: style, time: ThinkingOrbStyle.staticTime, ink: ink, isDark: isDark)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: paused)) { context in
                    ThinkingOrbFrame(style: style,
                                     time: context.date.timeIntervalSinceReferenceDate * style.speed,
                                     ink: ink, isDark: isDark)
                }
            }
        }
        .frame(width: ThinkingOrbStyle.size, height: ThinkingOrbStyle.size)
    }
}

/// One still frame of an orb at geometry time `time`.
struct ThinkingOrbFrame: View {
    let style: ThinkingOrbStyle
    let time: Double
    let ink: Color
    let isDark: Bool

    var body: some View {
        Canvas { context, _ in
            let tint = Self.rgb(ink)
            for dot in style.frame(at: time) {
                let shade = tint.shaded(white: dot.white, dark: isDark)
                let color = Color(.sRGB, red: shade.red / 255, green: shade.green / 255,
                                  blue: shade.blue / 255, opacity: dot.alpha)
                let rect = CGRect(x: dot.x - dot.radius, y: dot.y - dot.radius,
                                  width: dot.radius * 2, height: dot.radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(color))
            }
        }
        .frame(width: ThinkingOrbStyle.size, height: ThinkingOrbStyle.size)
    }

    /// The ink as whole 0...255 sRGB channels, as the JS tint parser yields.
    static func rgb(_ color: Color) -> ThinkingOrbRGB {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        func channel(_ c: CGFloat) -> Double { (Double(c) * 255).rounded() }
        return ThinkingOrbRGB(red: channel(srgb.redComponent), green: channel(srgb.greenComponent),
                              blue: channel(srgb.blueComponent))
    }
}
