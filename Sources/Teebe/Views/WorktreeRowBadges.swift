import SwiftUI

/// Keep the name readable in narrow windows. Sync counts remain in the row's
/// hover help when there is only room for local changes and merge status.
struct WorktreeRowBadges: View {
    let status: WorktreeStatus
    let info: SelectorModel.WorktreeInfo
    let isSelected: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                labels
                if info.hasSync {
                    Text(info.syncText).font(.system(size: 11)).monospacedDigit()
                        .hoverHelp("\(info.behind) to pull, \(info.ahead) to push, against the remote copy of this branch.",
                                   highlight: false)
                }
            }
            .fixedSize()
            HStack(spacing: 7) { labels }.fixedSize()
        }
        .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
    }

    /// Placeholder until the row redesign draws `status.mark`.
    @ViewBuilder
    private var labels: some View {
        if status.changeCount > 0 {
            Text("\(status.changeCount) change\(status.changeCount == 1 ? "" : "s")").font(.system(size: 10)).monospacedDigit()
        }
        if status.mark == .merged {
            Label("Merged", systemImage: "arrow.triangle.merge")
                .font(.system(size: 11, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.8))
                .padding(.horizontal, 6).frame(height: 20)
                .background((isSelected ? Color.white : Color.primary).opacity(isSelected ? 0.16 : 0.07),
                            in: RoundedRectangle(cornerRadius: 6))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Merged")
        }
    }
}
