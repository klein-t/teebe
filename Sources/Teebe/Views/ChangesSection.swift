import SwiftUI
import TeebeCore

/// CHANGES accordion section: commit box + grouped change list.
struct ChangesSection: View {
    @Bindable var app: AppModel
    @Bindable var worktree: WorktreeModel
    @Bindable var preview: PreviewModel
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "CHANGES", isOpen: isOpen, onToggle: { isOpen.toggle() }) {
                HStack(spacing: 8) {
                    countBadge(worktree.changeCount)
                    if let active = app.selector.selectedWorktree {
                        let info = app.selector.info(for: active)
                        Text(info.syncText)
                            .font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(Palette.secondaryText)
                    }
                }
            }

            if isOpen {
                VStack(spacing: 0) {
                    commitBox
                    ScrollView {
                        changeList
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .frame(maxHeight: isOpen ? .infinity : nil)
        .clipped()
    }

    private var commitBox: some View {
        VStack(spacing: 7) {
            TextField(
                "Message (⌘↩ to commit on \(app.selector.selectedWorktree?.branch ?? "—"))",
                text: $worktree.commitMessage,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .lineLimit(1...3)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .onSubmit { Task { await worktree.commitPending() } }

            Button {
                Task { await worktree.commitPending() }
            } label: {
                Text(commitLabel)
                    .font(.system(size: 12.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .foregroundStyle(commitEnabled ? .white : Palette.secondaryText)
                    .background(commitEnabled ? Palette.accent : Color.primary.opacity(0.05),
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(!commitEnabled)
            .keyboardShortcut(.return, modifiers: .command)   // ⌘↩ (matches the field's placeholder)
            .animation(.easeOut(duration: 0.2), value: commitEnabled)
            .animation(.snappy(duration: 0.22), value: worktree.changeCount)
        }
        .padding(.horizontal, 11).padding(.top, 8).padding(.bottom, 6)
    }

    private var commitEnabled: Bool {
        worktree.changeCount > 0 && !worktree.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var commitLabel: String {
        if worktree.changeCount == 0 { return "✓ Nothing to commit" }
        if worktree.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a message to commit" }
        return "Commit \(worktree.changeCount) change\(worktree.changeCount == 1 ? "" : "s")"
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            ForEach(worktree.changeGroups) { group in
                if !group.folder.isEmpty {
                    HStack(spacing: 6) {
                        Text("▾").font(.system(size: 13)).foregroundStyle(Palette.secondaryText).frame(width: 13)
                        Text(group.folder).font(.system(size: 12.5)).foregroundStyle(.primary)
                        Spacer()
                        Circle().fill(Palette.amber).frame(width: 6, height: 6)
                    }
                    .padding(.horizontal, 11).padding(.leading, 14).frame(height: 24)
                }
                ForEach(group.changes) { change in
                    changeRow(change, indented: !group.folder.isEmpty)
                }
            }
            if worktree.changeCount == 0 {
                Text("No changes")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 25).padding(.vertical, 4)
            }
        }
    }

    private func changeRow(_ change: FileChange, indented: Bool) -> some View {
        let selected = isSelected(change)
        return HStack(spacing: 7) {
            Image(systemName: "doc")
                .font(.system(size: 11))
                .foregroundStyle(selected ? .white : Palette.secondaryText)
            Text((change.path as NSString).lastPathComponent)
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            StatusLetter(change: change)
        }
        .padding(.leading, indented ? 41 : 25).padding(.trailing, 11).frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.accent : .clear)
        .foregroundStyle(selected ? .white : .primary)
        .animation(.easeInOut(duration: 0.18), value: selected)
        .contentShape(Rectangle())
        .onTapGesture { select(change) }
        .contextMenu {
            if change.isStaged {
                Button("Unstage") { Task { await worktree.unstage(change) } }
            } else {
                Button("Stage") { Task { await worktree.stage(change) } }
            }
            Button("Discard…", role: .destructive) { worktree.requestDiscard(change) }
        }
    }

    private func absolutePath(of change: FileChange) -> String? {
        worktree.worktreePath.map { $0 + "/" + change.path }
    }

    private func isSelected(_ change: FileChange) -> Bool {
        worktree.selectionSource == .changes && worktree.selectedPath == absolutePath(of: change)
    }

    /// Click a change → select it (highlight). Space then peeks its diff. If the
    /// diff peek is already open, follow the new selection live.
    private func select(_ change: FileChange) {
        guard let worktreePath = worktree.worktreePath else { return }
        let node = FileNode(path: worktreePath + "/" + change.path, isDirectory: false, change: change)
        worktree.selectedPath = node.path
        worktree.selectionSource = .changes
        if preview.isVisible {
            Task { await preview.update(for: node, worktreePath: worktreePath) }
        }
    }

    private func countBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(Palette.headerLabel)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .animation(.snappy(duration: 0.22), value: count)
    }
}
