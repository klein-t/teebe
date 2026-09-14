import SwiftUI

/// Neutral hover feedback shared by all lists. Selection keeps the accent fill;
/// only the hover layer animates so keyboard selection never leaves a fade trail.
private struct RowHighlightModifier: ViewModifier {
    let isSelected: Bool
    var onHoverChange: (Bool) -> Void
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                ZStack {
                    Color.primary.opacity(isHovered ? 0.06 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                    Palette.accent.opacity(isSelected ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
                onHoverChange(hovering)
            }
            .onDisappear {
                isHovered = false
                onHoverChange(false)
            }
    }
}

extension View {
    func rowHighlight(isSelected: Bool, onHoverChange: @escaping (Bool) -> Void = { _ in }) -> some View {
        modifier(RowHighlightModifier(isSelected: isSelected, onHoverChange: onHoverChange))
    }
}
