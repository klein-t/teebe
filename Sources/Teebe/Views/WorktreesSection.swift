import SwiftUI
import TeebeCore

/// WORKTREES accordion section: the list of a repo's worktrees with live pulse
/// and ahead/behind sync arrows.
struct WorktreesSection: View {
    @Bindable var app: AppModel
    @Binding var isOpen: Bool
    @Binding var collapsedGroups: Set<WorktreeGroup>
    /// Built once by RootView (which also sizes the window from it) and handed down.
    let list: WorktreeListPresentation
    let revealHeight: CGFloat
    // Not `private`: that would make the memberwise initializer private too, and this
    // view has no other reason to hand-roll one.
    @State var cleanupRepo: Repository?
    @State var pendingRemoval: Worktree?

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
                            recentProjects
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
                        .frame(height: max(0, revealHeight - (selector.selectedRepo == nil ? 0 : WorktreeListPresentation.repoHeight)))
                        // Keep the keyboard cursor visible as ↑/↓ move it. Snap, not
                        // animate (see FilesSection) — avoids the bounce-then-settle.
                        .onChange(of: selector.highlightedWorktree?.path) { _, path in
                            guard app.activeSection == .worktrees, let path else { return }
                            Task { @MainActor in
                                await Task.yield()
                                proxy.scrollTo(path, anchor: nil)
                            }
                        }
                }
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
                  let current = app.mergeStatus.entry(for: path), head != current.entry.worktree.head else { return }
            // Only this checkout committed, so only this row needs rechecking —
            // invalidating the whole list would regroup and resize every row.
            Task { await app.mergeStatus.recheck(path: path) }
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
        .padding(.vertical, WorktreeListPresentation.verticalPadding / 2)
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
                // System colors throughout: they are the only ones that follow light,
                // dark and Increase Contrast, so the row of headings stays consistent.
                GitStatusGlyph(symbol: group.kind.symbol).frame(width: 14, height: 15)
                    .foregroundStyle(headerTint(group.kind))
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

    /// A real menu section with a real Picker, so macOS draws the checkmark on the open
    /// project itself instead of us swapping a label's image for one.
    private var recentProjects: some View {
        Section("Recent Projects") {
            Picker("Recent Projects", selection: Binding(
                get: { selector.selectedRepo?.id },
                set: { id in
                    guard let repo = app.recentRepositories.first(where: { $0.id == id }) else { return }
                    Task { await selector.selectRepo(repo) }
                }
            )) {
                ForEach(app.recentRepositories.prefix(8)) { repo in
                    Text(app.repositoryTitle(repo)).tag(Optional(repo.id))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func headerTint(_ kind: WorktreeGroup) -> Color {
        switch kind {
        case .merged: .green
        case .localChanges: .orange
        case .broken: .red
        case .notMerged, .notChecked: .secondary
        }
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
        .padding(.horizontal, 11).frame(height: WorktreeListPresentation.repoHeight)
    }

    private func comparisonPicker(_ repo: Repository) -> some View {
        let saved = app.cleanupTarget(for: repo.path) ?? ""
        let targets = app.mergeStatus.snapshot?.targets
        let resolved = app.mergeStatus.snapshot?.target?.name
        return Menu {
            // A Picker, so macOS draws the checkmark on the chosen branch itself.
            Picker("Comparison branch", selection: Binding(
                get: { saved },
                set: { app.setCleanupTarget($0.isEmpty ? nil : $0, for: repo.path) }
            )) {
                Text(automaticLabel(targets?.automatic?.name)).tag("")
                ForEach(targets?.branches ?? []) { branch in Text(branch.name).tag(branch.ref) }
                if !saved.isEmpty, targets?.branches.contains(where: { $0.ref == saved }) != true {
                    Text("Saved branch not found. Choose another.").tag(saved)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // One affordance when nothing resolved: the list is flat, so the ask belongs
            // here once, not on every row.
            Text(list.needsTarget ? "Choose a comparison branch"
                 : (resolved ?? (saved.isEmpty ? "Automatic" : String(saved.split(separator: "/").suffix(2).joined(separator: "/")))))
                .font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(list.needsTarget ? Palette.accent : Palette.secondaryText)
        }
        .menuStyle(.borderlessButton)
        // Lower priority than the repo name: the branch is the part that may truncate.
        .frame(maxWidth: 220, alignment: .trailing).layoutPriority(-1)
        .accessibilityLabel("Comparison branch")
        .help("Comparison branch")
    }

    /// One name for the automatic choice, with the branch it actually resolved to.
    private func automaticLabel(_ name: String?) -> String {
        name.map { "Automatic (\($0))" } ?? "Automatic"
    }

    private func mergeIndicator(_ worktree: Worktree, isActive: Bool) -> some View {
        let local = selector.worktree.worktreePath == worktree.path ? selector.worktree.status : nil
        let presentation = MergeIndicatorPresentation(
            status: app.mergeStatus.entry(for: worktree.path, localStatus: local,
                                          localChangeCount: selector.info(for: worktree).changeCount),
            targetName: app.mergeStatus.snapshot?.target?.name, isChecking: app.mergeStatus.isChecking
        )
        return WorktreeStatusButton(presentation: presentation, isSelected: isActive,
                                    isChecking: app.mergeStatus.isChecking)
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
            // Nothing to compare against yet: the header asks for a branch once, so the
            // rows stay quiet. The button reveals itself on row hover (see rowHovered).
            if app.showMergeStatus, !worktree.isPrimary, !list.needsTarget {
                mergeIndicator(worktree, isActive: isActive)
            }
        }
        .padding(.leading, 30).padding(.trailing, 11).frame(height: WorktreeListPresentation.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowHighlight(isSelected: isActive)
        .foregroundStyle(isActive ? .white : .primary)
        .overlay {
            if isHighlighted, !isActive {
                RowHighlight.shape.strokeBorder(Palette.accent, lineWidth: 1.5)
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
