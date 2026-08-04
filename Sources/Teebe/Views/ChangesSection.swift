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
                // Just the count: the ahead/behind indicator lives on the worktree
                // rows — branch sync state isn't a property of the change list.
                CountBadge(count: worktree.changeCount, contextID: worktree.worktreePath)
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
                .padding(.top, Self.listTopPadding)
                .padding(.bottom, Self.listBottomPadding)
                .transition(.opacity)
            }
        }
        .clipped()
    }

    /// Tallest the change list hugs before it scrolls internally. Bounds how much the
    /// window grows for a worktree with many changes, so browsing between worktrees with
    /// very different change counts doesn't lurch the window. RootView's
    /// `changesContentHeight` mirrors this cap so the window math and the view agree.
    static let maxListHeight: CGFloat = 144   // ~6 rows, then scroll

    /// Row/padding metrics. RootView's `changesContentHeight` derives the window's
    /// wrap height from these — keep every literal here so the two can't desync.
    static let rowHeight: CGFloat = 24
    static let listTopPadding: CGFloat = 8
    static let listBottomPadding: CGFloat = 6

    /// Natural height of the change list, capped at `maxListHeight` so the section
    /// hugs its rows up to the cap and scrolls beyond it.
    private var listContentHeight: CGFloat {
        let natural = CGFloat(max(worktree.changeCount, 1)) * Self.rowHeight
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
                    .padding(.horizontal, 30).padding(.vertical, 4)
            }
        }
    }

    private func changeRow(_ change: FileChange, indented: Bool) -> some View {
        let selected = isSelected(change)
        return HStack(spacing: 7) {
            Image(systemName: change.iconName)
                .font(.system(size: 11))
                .foregroundStyle(selected ? .white : Palette.secondaryText)
            Text((change.path as NSString).lastPathComponent)
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            StatusLetter(change: change)
        }
        // Leading 30 lines the icon up with the FILES rows' icon column below.
        .padding(.leading, indented ? 46 : 30).padding(.trailing, 11).frame(height: Self.rowHeight)
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

}

/// The CHANGES header count. Digits roll (`numericText`) only when the count of the
/// *same* worktree changes (edits, stage/discard); a count arriving because the user
/// switched worktrees snaps into place — rolling between two unrelated worktrees'
/// totals reads as a glitch, not a change.
private struct CountBadge: View {
    let count: Int
    /// Identity of the thing being counted (the worktree path).
    let contextID: String?

    @State private var displayed = 0
    /// Which context `displayed` belongs to. Deliberately only updated when a count
    /// arrives: a worktree switch changes `contextID` first and the new status lands
    /// asynchronously later, so the mismatch at that moment is what marks the update
    /// as "different worktree → snap".
    @State private var displayedContext: String?

    var body: some View {
        Text("\(displayed)")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .contentTransition(.numericText(value: Double(displayed)))
            .foregroundStyle(Palette.headerLabel)
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 16)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .onAppear {
                displayed = count
                displayedContext = contextID
            }
            .onChange(of: count) { _, newCount in
                let sameWorktree = displayedContext == contextID
                displayedContext = contextID
                if sameWorktree {
                    withAnimation(.snappy(duration: 0.22)) { displayed = newCount }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { displayed = newCount }
                }
            }
    }
}
