import SwiftUI

/// Whether the row a view sits in is under the pointer. Published by `rowHighlight`
/// so a row's own controls can appear on hover without a second `onHover` per row.
private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

/// Neutral hover feedback shared by all lists. Selection keeps the accent fill;
/// only the hover layer animates so keyboard selection never leaves a fade trail.
/// Hover, selection and the keyboard cursor all use the same rounded rectangle.
private struct RowHighlightModifier: ViewModifier {
    let isSelected: Bool
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .environment(\.rowHovered, isHovered)
            .background {
                ZStack {
                    // A selected row does not also light up on hover — matching every
                    // Apple list, where the pointer only previews an unselected row.
                    RowHighlight.shape.fill(Color.primary.opacity(isHovered && !isSelected ? 0.06 : 0))
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
                    RowHighlight.shape.fill(Palette.accent.opacity(isSelected ? 1 : 0))
                }
                .padding(.horizontal, RowHighlight.horizontalInset)
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovered = hovering
            }
            .onDisappear {
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
