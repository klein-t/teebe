import AppKit
import SwiftUI

struct WorktreeResizeHandle: View {
    let height: CGFloat
    let onResize: (CGFloat) -> Void
    let onEnd: () -> Void
    @State private var startHeight: CGFloat?
    @State private var hovered = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
            Capsule().fill(hovered || startHeight != nil ? Palette.accent : Color.secondary.opacity(0.35))
                .frame(width: 28, height: 3)
        }
        .frame(height: 1 + WorktreeSectionSizing.dividerExtra)
        .frame(maxWidth: .infinity).contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if startHeight == nil { startHeight = height }
                onResize((startHeight ?? height) + value.translation.height)
            }
            .onEnded { _ in startHeight = nil; onEnd() })
        .onHover { value in
            guard value != hovered else { return }
            hovered = value
            if value { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
        }
        .onDisappear { if hovered { NSCursor.pop() } }
        .accessibilityElement()
        .accessibilityLabel("Worktrees section height")
        .accessibilityValue("\(Int(height)) points")
        .accessibilityAdjustableAction { direction in
            onResize(height + (direction == .increment ? 26 : -26)); onEnd()
        }
        .help("Drag to resize Worktrees and the window together")
    }
}
