import SwiftUI

/// The one-line notice under the lists after deleted worktrees were forgotten.
/// News, not an error: muted, and it stays until dismissed. In a window too
/// narrow for it, it slides while the pointer is on it, as an agent line does.
struct CleanupNoticeRow: View {
    let notice: String
    let dismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle").accessibilityHidden(true)
                HoverSlidingLine(text: notice)
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(IconButtonStyle(size: CGSize(width: 18, height: 18)))
                .foregroundStyle(Palette.secondaryText)
                .accessibilityLabel("Dismiss")
                .hoverHelp("Dismiss")
            }
            .font(.caption).foregroundStyle(Palette.secondaryText)
            .padding(.leading, 11).padding(.trailing, 6).padding(.vertical, 2)
        }
        .environment(\.rowHovered, hovered)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
