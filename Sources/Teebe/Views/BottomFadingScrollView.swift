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
            GeometryReader { geometry in
                let height = Self.fadeHeight(contentBottom: contentBottom, viewportHeight: geometry.size.height)
                VStack(spacing: 0) {
                    Rectangle().fill(.white)
                    LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: height)
                }
                // Keep the native scrollbar legible and independently interactive.
                .overlay(alignment: .trailing) { Rectangle().fill(.white).frame(width: 12) }
                .onChange(of: height, initial: true) { _, value in onFadeHeightChange?(value) }
            }
        }
    }
}
