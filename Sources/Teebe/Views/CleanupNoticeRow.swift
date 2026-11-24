import SwiftUI

/// How long the clean-up notice stays: until it has been in view for a while.
/// Time with the window covered, or with the pointer on the notice, does not
/// count, so it is never gone before it could be read. Pure.
struct NoticeLifetime: Equatable {
    static let timeInView: Duration = .seconds(8)
    static let tick: Duration = .milliseconds(500)
    private(set) var seen: Duration = .zero

    /// One tick passed. True once the notice has been in view long enough.
    mutating func advance(inView: Bool, hovered: Bool) -> Bool {
        if inView, !hovered { seen += Self.tick }
        return seen >= Self.timeInView
    }
}

/// The one-line notice under the lists after deleted worktrees were forgotten.
/// News, not an error: muted, and it leaves on its own (`NoticeLifetime`) or when
/// dismissed. In a window too narrow for it, it slides while the pointer is on
/// it, as an agent line does.
struct CleanupNoticeRow: View {
    let notice: String
    /// Whether any of the window can be seen right now.
    var isInView: () -> Bool = { true }
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
        // A new count is a new notice: its time starts over.
        .task(id: notice) {
            var lifetime = NoticeLifetime()
            while !Task.isCancelled {
                do { try await Task.sleep(for: NoticeLifetime.tick) } catch { return }
                if lifetime.advance(inView: isInView(), hovered: hovered) { return dismiss() }
            }
        }
    }
}
