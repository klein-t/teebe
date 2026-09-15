import SwiftUI
import TeebeCore

/// WORKTREES accordion section: the list of a repo's worktrees with live pulse
/// and ahead/behind sync arrows.
struct WorktreesSection: View {
    @Bindable var app: AppModel
    @Binding var isOpen: Bool
    @State private var cleanupRepo: Repository?
    @State private var pendingRemoval: Worktree?
    @State private var hoveredPath: String?
    @Binding var collapsedGroups: Set<WorktreeGroup>
    var revealHeight: CGFloat?

    init(app: AppModel, isOpen: Binding<Bool>, collapsedGroups: Binding<Set<WorktreeGroup>> = .constant([]),
         revealHeight: CGFloat? = nil) {
        self.app = app
        _isOpen = isOpen
        _collapsedGroups = collapsedGroups
        self.revealHeight = revealHeight
    }

    private var list: WorktreeListPresentation { app.worktreeList(collapsed: collapsedGroups) }

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
                if let repo = selector.selectedRepo { repoSubheader(repo) }
                ScrollViewReader { proxy in
                    ScrollView { worktreeListBody }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: max(0, listContentHeight - (selector.selectedRepo == nil ? 0 : Self.repoRowHeight)))
                        // Keep the keyboard cursor visible as ↑/↓ move it. Snap, not
                        // animate (see FilesSection) — avoids the bounce-then-settle.
                        .onChange(of: selector.highlightedWorktree?.path) { _, path in
                            guard app.activeSection == .worktrees, let path else { return }
                            if let group = list.groups.first(where: { $0.worktrees.contains { $0.path == path } }) {
                                collapsedGroups.remove(group.kind)
                            }
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(path, anchor: nil)
                            }
                        }
                }
                .transition(.opacity)
            }
        }
        .clipped()
        .task(id: mergeRefreshKey) {
            let repo = selector.selectedRepo
            await app.mergeStatus.refresh(repo: repo, targetOverride: repo.flatMap { app.cleanupTarget(for: $0.path) },
                                          enabled: app.showMergeStatus, revision: selector.mergeRevision)
        }
        .onChange(of: selector.worktree.status) { _, status in
            guard let path = selector.worktree.worktreePath, let head = status?.oid,
                  let entry = app.mergeStatus.entry(for: path), head != entry.worktree.head else { return }
            selector.invalidateMergeStatus()
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

    static let maxListHeight = WorktreeSectionSizing.defaultHeight
    static let rowHeight = WorktreeListPresentation.rowHeight
    static let repoRowHeight = WorktreeListPresentation.repoHeight
    static let listVerticalPadding = WorktreeListPresentation.verticalPadding / 2

    private var listContentHeight: CGFloat {
        revealHeight ?? min(list.naturalHeight, Self.maxListHeight)
    }

    private var worktreeListBody: some View {
        VStack(spacing: 0) {
            ForEach(list.pinned) { worktreeRow($0) }
            ForEach(list.groups) { group in
                groupHeader(group)
                if !collapsedGroups.contains(group.kind) {
                    ForEach(group.worktrees) { worktreeRow($0) }
                }
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

    private func groupHeader(_ group: WorktreeListPresentation.Group) -> some View {
        let collapsed = collapsedGroups.contains(group.kind)
        return Button {
            if collapsed { collapsedGroups.remove(group.kind) } else { collapsedGroups.insert(group.kind) }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                    .foregroundStyle(Palette.secondaryText)
                GitStatusGlyph(symbol: group.kind.symbol).frame(width: 14, height: 15)
                    .foregroundStyle(group.kind == .merged ? Palette.green
                                     : group.kind == .localChanges ? .orange
                                     : group.kind == .broken ? .red : Palette.secondaryText)
                Text(group.kind.title).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text("\(group.worktrees.count)").font(.system(size: 10)).monospacedDigit()
                    .foregroundStyle(Palette.secondaryText)
            }
            .padding(.horizontal, 12).frame(height: WorktreeListPresentation.groupHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).rowHighlight(isSelected: false)
        .accessibilityLabel("\(group.kind.title), \(group.worktrees.count) worktrees")
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .help("\(collapsed ? "Expand" : "Collapse") \(group.kind.title.lowercased()) worktrees")
    }

    private func repoSubheader(_ repo: Repository) -> some View {
        HStack(spacing: 7) {
            // No disclosure triangle: there's only ever one repo root to show, so a
            // collapse affordance would be a no-op. Reintroduce it if/when the
            // workspace can hold multiple repos.
            Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            Text(repo.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            if app.showMergeStatus { comparisonPicker(repo) }
        }
        .padding(.horizontal, 11).frame(height: Self.repoRowHeight)
    }

    private func comparisonPicker(_ repo: Repository) -> some View {
        let saved = app.cleanupTarget(for: repo.path) ?? ""
        let targets = app.mergeStatus.snapshot?.targets
        return Menu {
            Button { app.setCleanupTarget(nil, for: repo.path) } label: {
                Label("Automatic (\(targets?.automatic?.name ?? "default branch"))",
                      systemImage: saved.isEmpty ? "checkmark" : "arrow.triangle.branch")
            }
            Divider()
            ForEach(targets?.branches ?? []) { branch in
                Button { app.setCleanupTarget(branch.ref, for: repo.path) } label: {
                    Label(branch.name, systemImage: saved == branch.ref ? "checkmark" : "arrow.triangle.branch")
                }
            }
            if !saved.isEmpty, targets?.branches.contains(where: { $0.ref == saved }) != true {
                Text("Saved comparison branch unavailable")
            }
        } label: {
            Text("Compare: \(app.mergeStatus.snapshot?.target?.name ?? (saved.isEmpty ? "Automatic" : String(saved.split(separator: "/").suffix(2).joined(separator: "/"))))")
                .font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(Palette.secondaryText)
        }
        .menuStyle(.borderlessButton).fixedSize().frame(maxWidth: 220, alignment: .trailing)
        .accessibilityLabel("Comparison branch")
        .help("Choose where this project's work merges, such as dev or main. Uses locally available history.")
    }

    private func mergeIndicator(_ worktree: Worktree, isActive: Bool) -> some View {
        let local = selector.worktree.worktreePath == worktree.path ? selector.worktree.status : nil
        let presentation = MergeIndicatorPresentation(
            entry: app.mergeStatus.entry(for: worktree.path, localStatus: local),
            targetName: app.mergeStatus.snapshot?.target?.name, isChecking: app.mergeStatus.isChecking
        )
        return WorktreeStatusButton(presentation: presentation, isSelected: isActive,
                                    isChecking: app.mergeStatus.isChecking, informationOnly: true)
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
                    .opacity(hoveredPath == worktree.path ? 1 : 0)
                    .allowsHitTesting(hoveredPath == worktree.path)
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
        .onHover { hovered in
            if hovered { hoveredPath = worktree.path } else if hoveredPath == worktree.path { hoveredPath = nil }
        }
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
