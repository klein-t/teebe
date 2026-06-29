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
            SectionHeader(title: "CHANGES", isOpen: isOpen, isActive: app.activeSection == .changes, onToggle: { isOpen.toggle() }) {
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
                // Hug the rows (the window wraps content); cap at the content height
                // and scroll inside only when the window is dragged too short.
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            changeList
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: listContentHeight)
                        // Follow the selection when ↑/↓ moves it past the visible edge.
                        // Snap, not animate (see FilesSection): an animated scrollTo
                        // reads as a bounce against the row highlight + relayout.
                        .onChange(of: worktree.selectedPath) { _, sel in
                            guard app.activeSection == .changes, let sel else { return }
                            proxy.scrollTo(sel, anchor: nil)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 6)
                .transition(.opacity)
            }
        }
        .clipped()
    }

    /// Tallest the change list hugs before it scrolls internally. Bounds how much the
    /// window grows for a worktree with many changes, so browsing between worktrees with
    /// very different change counts doesn't lurch the window. RootView's
    /// `changesContentHeight` mirrors this cap so the window math and the view agree.
    static let maxListHeight: CGFloat = 144   // ~6 rows (24pt each), then scroll

    /// Natural height of the change list (rows are 24pt tall), capped at `maxListHeight`
    /// so the section hugs its rows up to the cap and scrolls beyond it.
    private var listContentHeight: CGFloat {
        let count = worktree.changeCount
        let natural: CGFloat = count == 0 ? 24 : CGFloat(count) * 24
        return min(natural, Self.maxListHeight)
    }

    private var changeList: some View {
        VStack(spacing: 0) {
            ForEach(worktree.changes) { change in
                changeRow(change, indented: false)
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
        // Snap, no cross-fade — avoids the trailing highlight when arrowing fast.
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
        .id(absolutePath(of: change) ?? change.path)   // matches selectedPath for scroll-to
    }

    private func absolutePath(of change: FileChange) -> String? {
        worktree.worktreePath.map { $0 + "/" + change.path }
    }

    private func isSelected(_ change: FileChange) -> Bool {
        app.activeSection == .changes && worktree.selectedPath == absolutePath(of: change)
    }

    /// Click a change → select it (highlight). Space then peeks its diff. If the
    /// diff peek is already open, follow the new selection live.
    private func select(_ change: FileChange) {
        guard let worktreePath = worktree.worktreePath else { return }
        let node = FileNode(path: worktreePath + "/" + change.path, isDirectory: false, change: change)
        app.activeSection = .changes
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
