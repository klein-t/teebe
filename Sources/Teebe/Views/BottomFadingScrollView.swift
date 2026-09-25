import SwiftUI

/// The fade ends at the viewport's bottom, directly against the divider. Bottom
/// breathing room belongs inside the scroll content, never below the mask.
struct BottomFadingScrollView<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var onFadeHeightChange: ((CGFloat) -> Void)?
    @State private var coordinateSpace = UUID()
    @State private var contentBottom: CGFloat = 0

    static func fadeHeight(contentBottom: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let remaining = contentBottom - viewportHeight
        guard viewportHeight > 0, remaining > 0.5 else { return 0 }
        return min(10, remaining, viewportHeight / 2)
    }

    /// Opaque above, fading below: both the viewport's full width, the fade ending
    /// exactly on its bottom edge.
    static func maskLayout(size: CGSize, fadeHeight: CGFloat) -> (solid: CGRect, fade: CGRect) {
        let fade = min(max(0, fadeHeight), size.height)
        return (CGRect(x: 0, y: 0, width: size.width, height: size.height - fade),
                CGRect(x: 0, y: size.height - fade, width: size.width, height: fade))
    }

    var body: some View {
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
        .mask {
            // The whole viewport, scrollbar strip included: a selected row fades
            // right to its trailing edge (overlay scrollers fade with it).
            GeometryReader { geometry in
                let height = Self.fadeHeight(contentBottom: contentBottom, viewportHeight: geometry.size.height)
                let layout = Self.maskLayout(size: geometry.size, fadeHeight: height)
                // One gradient over the whole viewport: two abutting shapes left a
                // hairline seam where their anti-aliased edges met.
                LinearGradient(stops: [.init(color: .white, location: 0),
                                       .init(color: .white, location: layout.solid.height / max(1, geometry.size.height)),
                                       .init(color: height > 0 ? .clear : .white, location: 1)],
                               startPoint: .top, endPoint: .bottom)
                .onChange(of: height, initial: true) { _, value in onFadeHeightChange?(value) }
            }
        }
    }
}
