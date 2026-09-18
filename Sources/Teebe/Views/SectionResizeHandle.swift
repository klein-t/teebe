import AppKit
import SwiftUI

/// The drag divider under a resizable accordion section.
struct SectionResizeHandle: View {
    /// The section it resizes, as its header names it ("Worktrees", "Changes").
    let section: String
    let height: CGFloat
    let onResize: (CGFloat) -> Void
    let onEnd: () -> Void
    @State private var startHeight: CGFloat?
    @State private var hovered = false
    /// Reset by SwiftUI when the drag ends *or is cancelled*, which is what `onEnded`
    /// alone cannot see — see `onChange(of: dragging)`.
    @GestureState private var dragging = false

    /// Drawn thin, grabbed thick: the capsule stays 3pt while the target is a
    /// comfortable 12pt, centred on it.
    private static let hitPadding: CGFloat = (12 - (1 + SectionSizing.dividerExtra)) / 2

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Capsule().fill(hovered || dragging ? Palette.accent : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 3)
        }
        .frame(height: 1 + SectionSizing.dividerExtra)
        .frame(maxWidth: .infinity)
        // Grow, take the hit shape, then give the layout its height back: the divider
        // still occupies `dividerExtra` in the window maths, but is grabbable at 12pt.
        .padding(.vertical, Self.hitPadding)
        .contentShape(Rectangle())
        .padding(.vertical, -Self.hitPadding)
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { value in
                if startHeight == nil { startHeight = height }
                onResize((startHeight ?? height) + value.translation.height)
            })
        // The window is held still for the whole drag and sized once at the end, so a
        // drag that never reports an end leaves it stuck at the height it started from.
        // `onEnded` misses a cancelled gesture (the app deactivating, the view being
        // rebuilt under the pointer); `@GestureState` is reset on both.
        .onChange(of: dragging) { _, active in
            guard !active else { return }
            startHeight = nil
            onEnd()
        }
        .modifier(ResizeCursor(active: hovered || dragging))
        .onHover { hovered = $0 }
        .accessibilityElement()
        .accessibilityLabel("\(section) section height")
        .accessibilityAdjustableAction { direction in
            onResize(height + (direction == .increment ? 26 : -26)); onEnd()
        }
        .help("Resize the \(section) list")
    }
}

/// One push, one pop. `NSCursor.push/pop` is a stack, so an unbalanced pair (popping
/// mid-drag, or missing a hover-out) leaves the resize cursor stuck app-wide.
private struct ResizeCursor: ViewModifier {
    let active: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.pointerStyle(active ? .frameResize(position: .top) : nil)
        } else {
            content
                .onChange(of: active) { _, isActive in
                    guard isActive != pushed else { return }
                    pushed = isActive
                    if isActive { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .onDisappear { if pushed { pushed = false; NSCursor.pop() } }
        }
    }
}
