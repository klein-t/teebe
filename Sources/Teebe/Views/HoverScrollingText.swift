import SwiftUI

/// A clipped long label scrolls once on deliberate row hover, then stays at its
/// end until the pointer leaves. No timer or animation runs for unhovered rows.
struct HoverScrollingText: View {
    let text: String
    @Environment(\.rowHovered) private var hovered
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var available: CGFloat = 0
    @State private var intrinsic: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var distance: CGFloat { max(0, intrinsic - available) }
    private var scrolling: Bool { hovered && !reduceMotion && distance > 1 }

    var body: some View {
        Text(text).lineLimit(1).truncationMode(.middle)
            .opacity(scrolling ? 0 : 1)
            .background {
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in available = width }
                }
            }
            .overlay(alignment: .leading) {
                Text(text).fixedSize(horizontal: true, vertical: false)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in intrinsic = width }
                        }
                    }
                    .offset(x: offset).opacity(scrolling ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .clipped()
            .help(text)
            .task(id: ScrollIdentity(text: text, scrolling: scrolling, distance: distance)) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { offset = 0 }
                guard scrolling else { return }
                do { try await Task.sleep(for: .milliseconds(550)) } catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.linear(duration: Double(distance / 32))) { offset = -distance }
            }
    }

    private struct ScrollIdentity: Equatable {
        let text: String
        let scrolling: Bool
        let distance: CGFloat
    }
}
