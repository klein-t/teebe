import AppKit
import SwiftUI

/// A list that shows, at its bottom edge, that more rows continue below. On macOS 26
/// that is the system's soft scroll-edge effect, so rows slip under the edge the
/// way they do under a toolbar; before that, a short eased fade with a faint shadow
/// along the edge. Either way it shows only while content is below, and it sits at
/// the viewport's bottom, directly against the divider (or the window edge). Bottom
/// breathing room belongs inside the scroll content, never below the edge.
struct BottomFadingScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var onFadeHeightChange: ((CGFloat) -> Void)?
    @State private var coordinateSpace = UUID()
    @State private var contentBottom: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    static var fadeLength: CGFloat { 12 }

    static func fadeHeight(contentBottom: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let remaining = contentBottom - viewportHeight
        guard viewportHeight > 0, remaining > 0.5 else { return 0 }
        return min(fadeLength, remaining, viewportHeight / 2)
    }

    /// The fallback fade's opacity at `progress` (0 where it starts, 1 at the
    /// viewport's bottom). Ease-in: rows stay nearly solid and drop away over the
    /// last points, instead of a linear wash across the whole fade.
    static func fadeOpacity(at progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return 1 - clamped * clamped
    }

    /// Opaque above, fading below: both the viewport's full width, the fade ending
    /// exactly on its bottom edge.
    static func maskLayout(size: CGSize, fadeHeight: CGFloat) -> (solid: CGRect, fade: CGRect) {
        let fade = min(max(0, fadeHeight), size.height)
        return (CGRect(x: 0, y: 0, width: size.width, height: size.height - fade),
                CGRect(x: 0, y: size.height - fade, width: size.width, height: fade))
    }

    /// The system edge effect, unless a debug run asks for the fallback to look at it.
    static var usesSystemEdgeEffect: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["TEEBE_FALLBACK_FADE"] != nil { return false }
        #endif
        if #available(macOS 26, *) { return true }
        return false
    }

    var body: some View {
        let fade = Self.fadeHeight(contentBottom: contentBottom, viewportHeight: viewportHeight)
        bottomEdge(scroll, fade: fade)
            .onChange(of: fade, initial: true) { _, value in onFadeHeightChange?(value) }
    }

    private var scroll: some View {
        ScrollView {
            content()
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.frame(in: .named(coordinateSpace)).maxY,
                                             initial: true) { _, bottom in contentBottom = bottom }
                    }
                }
        }
        .coordinateSpace(name: coordinateSpace)
        .background {
            GeometryReader { geometry in
                Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in viewportHeight = height }
            }
        }
    }

    @ViewBuilder
    private func bottomEdge(_ scroll: some View, fade: CGFloat) -> some View {
        // The edge-effect API ships with the macOS 26 SDK (Swift 6.2); older
        // toolchains build the gradient fallback only.
        #if compiler(>=6.2)
        if #available(macOS 26, *), Self.usesSystemEdgeEffect {
            scroll
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(fade == 0, for: .bottom)
                // The system draws the edge effect only where content passes under
                // a bar. This one is the edge itself: a point tall, at the divider,
                // and invisible (a fully clear bar doesn't count as one).
                .safeAreaBar(edge: .bottom) {
                    Color.black.opacity(0.001).frame(height: 1).allowsHitTesting(false)
                }
        } else {
            gradientEdge(scroll, fade: fade)
        }
        #else
        gradientEdge(scroll, fade: fade)
        #endif
    }

    private func gradientEdge(_ scroll: some View, fade: CGFloat) -> some View {
        scroll
        .mask {
            // The whole viewport, scrollbar strip included, as one gradient:
            // two abutting shapes left a hairline seam between them.
            GeometryReader { geometry in
                let layout = Self.maskLayout(size: geometry.size, fadeHeight: fade)
                LinearGradient(stops: Self.maskStops(solid: layout.solid.height, total: geometry.size.height),
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .overlay(alignment: .bottom) {
            // A faint shadow along the edge, so rows read as slipping under it.
            LinearGradient(colors: [.clear, Self.edgeShadow], startPoint: .top, endPoint: .bottom)
                .frame(height: 4)
                .opacity(fade > 0 ? 1 : 0)
                .allowsHitTesting(false)
        }
    }

    private static func maskStops(solid: CGFloat, total: CGFloat) -> [Gradient.Stop] {
        guard total > 0, solid < total else { return [.init(color: .white, location: 0), .init(color: .white, location: 1)] }
        let start = solid / total
        let steps = 8
        return [.init(color: .white, location: 0)] + (0...steps).map { step in
            let progress = CGFloat(step) / CGFloat(steps)
            return .init(color: .white.opacity(fadeOpacity(at: progress)), location: start + (1 - start) * progress)
        }
    }

    private static var edgeShadow: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(white: 0, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.28 : 0.07)
        })
    }
}
