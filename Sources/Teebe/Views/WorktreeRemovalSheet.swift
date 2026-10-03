import SwiftUI

/// The confirmation behind every worktree removal: a row's trash or "Remove
/// Worktree…", and the Safe to delete group's remove-all. A
/// sheet rather than a confirmation dialog, because it holds a checkbox.
struct WorktreeRemovalSheet: View {
    let title: String
    /// Every worktree it will remove: one for a row, all of them for remove-all.
    let items: [WorktreeRemovalItem]
    let facts: [WorktreeCardFact]
    /// Gitignored files that go for good: one notice per worktree that has some.
    var ignored: [WorktreeIgnoredNotice] = []
    let explanation: String
    /// The remembered "Also delete the branch" choice; nil hides the checkbox.
    var deleteBranch: Binding<Bool>?
    var deleteBranchTitle = "Also delete the branch"
    /// False when Git would refuse: the button stays, disabled, and the facts say why.
    var canConfirm = true
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    private static let rowHeight: CGFloat = 40
    /// Rows shown before the list scrolls.
    private static let visibleRows = 6
    private static let hairline = Color(nsColor: .separatorColor)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typography.heading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 6)
            Text(explanation)
                .font(Typography.body).foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if !items.isEmpty { itemList.padding(.top, 12) }
            if !facts.isEmpty || !ignored.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { WorktreeFactRow(fact: $0.element, font: Typography.body) }
                    ForEach(Array(ignored.enumerated()), id: \.offset) { IgnoredFilesNotice(notice: $0.element) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.top, 10)
            }
            if let deleteBranch {
                Toggle(deleteBranchTitle, isOn: deleteBranch)
                    .toggleStyle(.checkbox)
                    .font(Typography.body)
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Remove", role: .destructive) {
                    dismiss()
                    onConfirm()
                }
                .buttonStyle(DestructiveButtonStyle())
                .disabled(!canConfirm)
            }
            .padding(.top, 16)
        }
        .padding(18)
        .frame(width: 340)
    }

    /// An inset list: hairline-separated rows in a rounded container, scrolling
    /// once there are more than `visibleRows`.
    private var itemList: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.path) { index, item in
                    if index > 0 { Self.hairline.frame(height: 0.5).padding(.leading, 36) }
                    itemRow(item)
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: CGFloat(min(items.count, Self.visibleRows)) * Self.rowHeight
               + CGFloat(max(min(items.count, Self.visibleRows) - 1, 0)) * 0.5)
        .background(Color.primary.opacity(0.04), in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Self.hairline, lineWidth: 0.5))
    }

    private func itemRow(_ item: WorktreeRemovalItem) -> some View {
        HStack(spacing: 8) {
            Group {
                if item.isMerged {
                    WorktreeMarkView(mark: .merged)
                } else {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(Typography.bodyEmphasis)
                Text(item.displayPath).font(Typography.secondary).foregroundStyle(.secondary)
            }
            .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
    }
}

/// One worktree's gitignored files: how many go for good, the names worth seeing
/// first, and every file in a list that expands.
private struct IgnoredFilesNotice: View {
    let notice: WorktreeIgnoredNotice
    @State private var isExpanded = false
    /// Rows the expanded list draws before saying how many more there are.
    private static let shownLimit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            WorktreeFactRow(fact: WorktreeCardFact(icon: .ignoredFiles, text: notice.summary, tone: .warn), font: Typography.body)
            Group {
                if let names = notice.names {
                    Text(names).font(Typography.secondary).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                if !notice.files.isEmpty {
                    DisclosureGroup(isExpanded: $isExpanded) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(notice.files.prefix(Self.shownLimit), id: \.self) { path in
                                    Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                if let more {
                                    Text(more).font(Typography.secondary).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 110)
                    } label: {
                        Text("Show files").font(Typography.secondary).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.leading, 21)
        }
    }

    private var more: String? {
        let hidden = notice.files.count - min(notice.files.count, Self.shownLimit)
        guard hidden > 0 || notice.isTruncated else { return nil }
        return notice.isTruncated ? "and more" : "and \(hidden.formatted(.number)) more"
    }
}

/// A red, filled button drawn by hand: the system's tinted prominent style draws
/// nothing at all in an inactive light-mode window, or when disabled.
private struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .systemRed).opacity(configuration.isPressed ? 0.8 : 1)))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
    }
}
