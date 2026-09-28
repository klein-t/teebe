import SwiftUI

/// The confirmation behind every worktree removal: a row's trash or "Remove
/// Worktree…", and the Safe to delete group's remove-all. A
/// sheet rather than a confirmation dialog, because it holds a checkbox.
struct WorktreeRemovalSheet: View {
    let title: String
    /// Remove-all only: every worktree it will remove.
    var items: [WorktreeRemovalItem] = []
    let facts: [WorktreeCardFact]
    let explanation: String
    /// The remembered "Also delete the branch" choice; nil hides the checkbox.
    var deleteBranch: Binding<Bool>?
    var deleteBranchTitle = "Also delete the branch"
    /// False when Git would refuse: the button stays, disabled, and the facts say why.
    var canConfirm = true
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Typography.heading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            if !items.isEmpty { itemList.padding(.bottom, 10) }
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { WorktreeFactRow(fact: $0.element, font: Typography.body) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 12)
            }
            Text(explanation)
                .font(Typography.body).foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
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

    /// Branch and folder of each worktree, scrolling once the list gets long.
    private var itemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(Typography.bodyEmphasis)
                        Text(item.path).font(Typography.secondary).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).truncationMode(.middle)
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: CGFloat(min(items.count, 6)) * 36)
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
