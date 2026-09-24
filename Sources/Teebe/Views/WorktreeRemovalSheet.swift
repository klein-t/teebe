import SwiftUI

/// The confirmation behind every worktree removal: a row's trash or "Remove
/// Worktree…", forgetting missing worktrees, and the Safe to delete clean-up. A
/// sheet rather than a confirmation dialog, because it holds a checkbox.
struct WorktreeRemovalSheet: View {
    let title: String
    let facts: [WorktreeCardFact]
    let explanation: String
    /// The remembered "Also delete the branch" choice; nil hides the checkbox.
    var deleteBranch: Binding<Bool>?
    var deleteBranchTitle = "Also delete the branch"
    var actionTitle = "Remove"
    /// False when Git would refuse: the button stays, disabled, and the facts say why.
    var canConfirm = true
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(facts.enumerated()), id: \.offset) { WorktreeFactRow(fact: $0.element) }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.bottom, 12)
            }
            Text(explanation)
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let deleteBranch {
                Toggle(deleteBranchTitle, isOn: deleteBranch)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .padding(.top, 12)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(actionTitle, role: .destructive) {
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
