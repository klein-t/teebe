import SwiftUI

/// Whether the row a view sits in is under the pointer. Published by `rowHighlight`
/// so a row's own controls can appear on hover without a second hover tracker per row.
private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

/// One row owns hover at a time, even when a recycled anchor misses its exit.
/// Clearing only the previous row keeps pointer movement local and adds no timer.
@MainActor
private final class RowHoverOwner {
    static let shared = RowHoverOwner()
    private var current: UUID?
    private var clear: (() -> Void)?

    func enter(_ id: UUID, clear: @escaping () -> Void) {
        guard current != id else { return }
        self.clear?()
        current = id
        self.clear = clear
    }

    func exit(_ id: UUID) {
        guard current == id else { return }
        let previous = clear
        current = nil
        clear = nil
        previous?()
    }
}

/// Neutral hover feedback shared by all lists. Selection keeps the accent fill;
/// hover fades in and clears immediately so moving down a list leaves no trail.
/// Hover, selection and the keyboard cursor all use the same rounded rectangle.
private struct RowHighlightModifier: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @State private var hoverID = UUID()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.rowHovered, isHovered)
            .background {
                ZStack {
                    // A selected row does not also light up on hover — matching every
                    // Apple list, where the pointer only previews an unselected row.
                    RowHighlight.shape.fill(Color.primary.opacity(isHovered && !isSelected ? 0.06 : 0))
                        .animation(reduceMotion || !isHovered ? nil : .easeOut(duration: 0.12), value: isHovered)
                    RowHighlight.shape.fill(Palette.accent.opacity(isSelected ? 1 : 0))
                }
                .padding(.horizontal, RowHighlight.horizontalInset)
            }
            .contentShape(Rectangle())
            .pointerHover { hovering in
                if hovering {
                    RowHoverOwner.shared.enter(hoverID) { isHovered = false }
                    isHovered = true
                } else {
                    RowHoverOwner.shared.exit(hoverID)
                }
            }
            .onDisappear {
                RowHoverOwner.shared.exit(hoverID)
                isHovered = false
            }
    }
}

/// The one row shape: hover fill, selection fill and the keyboard cursor's outline.
enum RowHighlight {
    static let cornerRadius: CGFloat = 4
    /// Margin between the highlight and the window's side edges, so a hovered or
    /// selected row reads as a pill inside the list rather than a band running into
    /// the window frame.
    static let horizontalInset: CGFloat = 6
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius) }
}

extension View {
    func rowHighlight(isSelected: Bool) -> some View {
        modifier(RowHighlightModifier(isSelected: isSelected))
    }
}
