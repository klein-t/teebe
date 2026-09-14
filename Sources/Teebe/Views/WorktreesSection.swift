import SwiftUI
import TeebeCore

/// WORKTREES accordion section: the list of a repo's worktrees with live pulse
/// and ahead/behind sync arrows.
struct WorktreesSection: View {
    @Bindable var app: AppModel
    @Binding var isOpen: Bool
    @State private var cleanupRepo: Repository?
    @State private var pendingRemoval: Worktree?

    private var selector: SelectorModel { app.selector }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "WORKTREES", isOpen: isOpen, isActive: app.activeSection == .worktrees, onToggle: { isOpen.toggle() }) {
                if isOpen {
                    HStack(spacing: 2) {
                        Button { app.presentAddRepositoryPanel() } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .help("Add Repository")
                        Menu {
                            Button { app.presentAddRepositoryPanel() } label: {
                                Label("Add Repository…", systemImage: "folder.badge.plus")
                            }
                            if let selected = selector.selectedRepo {
                                Button { app.presentNewWorktreePanel() } label: {
                                    Label("New Worktree…", systemImage: "plus.square.on.square")
                                }
                                Button { cleanupRepo = selected } label: {
                                    Label("Clean up worktrees…", systemImage: "checkmark.circle")
                                }
                                Button(role: .destructive) { app.removeRepository(selected) } label: {
                                    Label("Remove Project from List", systemImage: "folder.badge.minus")
                                }
                            }
                            Divider()
                            Button {} label: {
                                Label("Recent Projects", systemImage: "clock")
                            }
                            .disabled(true)
                            ForEach(app.recentRepositories) { repo in
                                Button { Task { await selector.selectRepo(repo) } } label: {
                                    Label(app.repositoryTitle(repo), systemImage: selector.selectedRepo?.id == repo.id ? "checkmark" : "folder")
                                }
                                .help(repo.path)
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText).hoverChip()
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Repository actions")
                        Button { Task { await selector.refreshWorktrees() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .help("Refresh worktrees")
                    }
                } else if let active = selector.selectedWorktree {
                    HStack(spacing: 5) {
                        // The dot carries the agent state too (amber = needs you),
                        // so "needs you" stays visible even with the section folded.
                        LiveDot(active: selector.info(for: active).isLive,
                                agent: selector.info(for: active).agentState)
                        // Same treatment as the collapsed FILES header's branch label;
                        // the accent colour (+ dot) marks this one as the active worktree.
                        Text(active.branch ?? active.name)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                }
            }

            if isOpen {
                // Hug the rows (the window wraps content), but cap at the content
                // height and scroll inside when the window is dragged too short — the
                // other headers must never get pushed off-screen.
                ScrollViewReader { proxy in
                    ScrollView { worktreeListBody }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(maxHeight: listContentHeight)
                        // Keep the keyboard cursor visible as ↑/↓ move it. Snap, not
                        // animate (see FilesSection) — avoids the bounce-then-settle.
                        .onChange(of: selector.highlightedWorktree?.path) { _, path in
                            guard app.activeSection == .worktrees, let path else { return }
                            proxy.scrollTo(path, anchor: nil)
                        }
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .task(id: mergeRefreshKey) {
            let repo = selector.selectedRepo
            await app.mergeStatus.refresh(repo: repo, targetOverride: repo.flatMap { app.cleanupTarget(for: $0.path) },
                                          enabled: app.showMergeStatus)
        }
        .sheet(item: $cleanupRepo) { repo in
            WorktreeCleanupView(app: app, repo: repo)
        }
        .confirmationDialog(
            "Remove worktree \"\(pendingRemoval?.branch ?? pendingRemoval?.name ?? "")\"?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Worktree", role: .destructive) {
                guard let worktree = pendingRemoval else { return }
                pendingRemoval = nil
                app.removeWorktree(worktree)
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("This removes the worktree folder from your Mac. The branch is kept.")
        }
    }

    private struct MergeRefreshKey: Equatable {
        let repoPath: String?
        let enabled: Bool
        let targetRevision: Int
        let historyRevision: Int
    }

    private var mergeRefreshKey: MergeRefreshKey {
        MergeRefreshKey(repoPath: selector.selectedRepo?.path, enabled: app.showMergeStatus,
                        targetRevision: app.cleanupTargetRevision, historyRevision: selector.mergeRevision)
    }

    /// Tallest the worktree list hugs before it scrolls internally (repo row + ~6
    /// worktrees). Keeps the window from ballooning on a repo with many worktrees;
    /// RootView's `worktreesContentHeight` mirrors this cap.
    static let maxListHeight: CGFloat = 200

    /// Row/padding metrics. RootView's `worktreesContentHeight` derives the window's
    /// wrap height from these — keep every literal here so the two can't desync.
    static let rowHeight: CGFloat = 26
    static let repoRowHeight: CGFloat = 25
    static let listVerticalPadding: CGFloat = 4

    /// Natural height of the worktree list, capped at `maxListHeight` so the section
    /// hugs its rows up to the cap and scrolls beyond it.
    private var listContentHeight: CGFloat {
        let repoRow: CGFloat = selector.selectedRepo != nil ? Self.repoRowHeight : 0
        let rows = CGFloat(max(selector.worktrees.count, 1)) * Self.rowHeight
        return min(Self.listVerticalPadding * 2 + repoRow + rows, Self.maxListHeight)
    }

    private var worktreeListBody: some View {
        VStack(spacing: 0) {
            if let repo = selector.selectedRepo {
                repoSubheader(repo)
            }
            ForEach(selector.worktrees) { worktree in
                worktreeRow(worktree)
            }
            if selector.worktrees.isEmpty {
                Text(app.repositories.isEmpty ? "No repository added" : "No worktrees")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 25).padding(.vertical, 5)
            }
        }
        .padding(.vertical, Self.listVerticalPadding)
    }

    private func repoSubheader(_ repo: Repository) -> some View {
        HStack(spacing: 7) {
            // No disclosure triangle: there's only ever one repo root to show, so a
            // collapse affordance would be a no-op. Reintroduce it if/when the
            // workspace can hold multiple repos.
            Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            Text(repo.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            // The sync indicator belongs on individual worktree rows, not the repo
            // root — the root isn't itself a branch with an ahead/behind count.
        }
        .padding(.horizontal, 11).frame(height: Self.repoRowHeight)
    }

    private func mergeIndicator(_ worktree: Worktree, isActive: Bool) -> some View {
        let entry = app.mergeStatus.entry(for: worktree.path)
        let status = entry?.mergeStatus ?? .unknown
        let symbol = status == .merged ? "arrow.triangle.merge" : (status == .notConfirmed ? "circle.dotted" : "questionmark.circle")
        return Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium)).frame(width: 15)
            .foregroundStyle(isActive ? .white.opacity(0.85) : (status == .merged ? Palette.green : Palette.secondaryText))
            .help(mergeDescription(entry))
            .accessibilityLabel(mergeDescription(entry))
    }

    private func mergeDescription(_ entry: CleanupEntry?) -> String {
        guard let entry else { return app.mergeStatus.isChecking ? "Checking merge status…" : "Merge status unavailable" }
        guard let target = app.mergeStatus.snapshot?.target else { return "Choose a merge target in Clean up worktrees." }
        switch entry.mergeStatus {
        case .merged:
            return "Commits included in \(target.name)." + (entry.hasLocalChanges ? " This folder still has local changes." : " This does not mean the folder is safe to remove.")
        case .notConfirmed:
            return "Merge into \(target.name) not confirmed. Squash merges may not be recognized."
        case .unknown:
            return entry.problem ?? "Merge status unavailable"
        }
    }

    private func worktreeRow(_ worktree: Worktree) -> some View {
        let info = selector.info(for: worktree)
        let isActive = selector.selectedWorktree?.path == worktree.path
        // The keyboard cursor (only while WORKTREES is the active section): an outline,
        // distinct from the filled accent of the committed worktree. Enter commits it.
        let isHighlighted = app.activeSection == .worktrees && selector.highlightedWorktree?.path == worktree.path
        return HStack(spacing: 7) {
            LiveDot(active: info.isLive, agent: info.agentState)
                .frame(width: 11) // Align the label with the Changes list's icon column.
            Text(worktree.branch ?? worktree.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            // "↓0 ↑0" is pure noise — only show the sync arrows once there is
            // something to pull or push.
            if info.hasSync {
                Text(info.syncText)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(isActive ? .white.opacity(0.85) : Palette.secondaryText)
                    .help("\(info.behind) commits behind, \(info.ahead) ahead of the tracked upstream branch. Uses locally available Git data.")
            }
            if app.showMergeStatus, !worktree.isPrimary {
                mergeIndicator(worktree, isActive: isActive)
            }
        }
        .padding(.leading, 30).padding(.trailing, 11).frame(height: Self.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowHighlight(isSelected: isActive)
        .foregroundStyle(isActive ? .white : .primary)
        .overlay {
            if isHighlighted, !isActive {
                RoundedRectangle(cornerRadius: 4).strokeBorder(Palette.accent, lineWidth: 1.5)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture {
            app.activeSection = .worktrees
            selector.highlightedWorktree = worktree
            Task { await selector.selectWorktree(worktree) }
        }
        .contextMenu {
            Button("Open in Finder") { app.revealPath(worktree.path) }
            Button("Open in Terminal") { app.openTerminal(at: worktree.path) }
            if !worktree.isPrimary {
                Button("Remove Worktree…", role: .destructive) { pendingRemoval = worktree }
                    .disabled(worktree.isLocked)
            }
        }
        .id(worktree.path)   // scroll-to target for keyboard highlight
    }
}
