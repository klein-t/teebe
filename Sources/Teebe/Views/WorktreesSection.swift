import SwiftUI
import TeebeCore

/// WORKTREES accordion section: the list of a repo's worktrees, each with its one
/// status mark, a hover card, a hover trash where removal is safe, and sync arrows.
struct WorktreesSection: View {
    @Bindable var app: AppModel
    @Binding var isOpen: Bool
    @Binding var collapsedGroups: Set<WorktreeGroup>
    /// Built once by RootView (which also sizes the window from it) and handed down.
    let list: WorktreeListPresentation
    let revealHeight: CGFloat
    // Not `private`: that would make the memberwise initializer private too, and this
    // view has no other reason to hand-roll one.
    @State var confirmation: RemovalConfirmation?

    /// The removal being confirmed. What runs is captured when the sheet opens (a
    /// row's action, the clean-up's folders), so the list can keep changing
    /// underneath; confirming re-checks it in full and refuses what changed.
    enum RemovalConfirmation: Identifiable {
        /// nil action: nothing current to act on yet (the row is being checked).
        case worktree(Worktree, WorktreeStatus.TrashAction?)
        case cleanup([CleanupEntry], skipped: [WorktreeCardFact])

        var id: String {
            switch self {
            case .worktree(let worktree, _): "worktree:" + worktree.path
            case .cleanup(let entries, _): "cleanup:" + entries.map(\.id).joined(separator: "\n")
            }
        }
    }

    private var selector: SelectorModel { app.selector }

    /// Fetch now, whenever it last ran, then re-read the repository.
    private func refresh() {
        Task {
            await app.refreshRemotes(force: true)
            await selector.refreshWorktrees()
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "WORKTREES", isOpen: isOpen, isActive: app.activeSection == .worktrees, onToggle: { isOpen.toggle() }) {
                if isOpen {
                    HStack(spacing: 2) {
                        Button { app.presentNewWorktree() } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .disabled(selector.selectedRepo == nil)
                        .hoverHelp("New worktree")
                        Button { refresh() } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .hoverHelp("Fetch and refresh")
                        Menu {
                            projectSwitcher
                            Divider()
                            Button { app.presentAddRepositoryPanel() } label: {
                                Label("Add Repository…", systemImage: "folder.badge.plus")
                            }
                            Button(role: .destructive) {
                                guard let selected = selector.selectedRepo else { return }
                                app.removeRepository(selected)
                            } label: {
                                Label("Remove \"\(selector.selectedRepo.map(app.repositoryTitle) ?? "")\" from List",
                                      systemImage: "folder.badge.minus")
                            }
                            .disabled(selector.selectedRepo == nil)
                            Divider()
                            Toggle(WorktreePreferences.groupingTitle, isOn: $app.groupWorktreesByMergeStatus)
                            Toggle(WorktreePreferences.fetchTitle, isOn: $app.fetchAutomatically)
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText).hoverChip()
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .hoverHelp("Repository actions")
                    }
                } else if let active = selector.selectedWorktree {
                    HStack(spacing: 3) {
                        // The row's mark, so "working" and "needs you" stay visible
                        // even with the section folded.
                        WorktreeMarkView(mark: app.worktreeStatus(for: active).mark, paused: selector.isLowPower)
                            .frame(width: 18, height: 20)
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
                    BottomFadingScrollView { worktreeListBody }
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
            await app.mergeStatus.refresh(repo: repo, extraTarget: repo.flatMap { app.extraMergeTarget(for: $0.path) },
                                          enabled: true, revision: selector.mergeRevision)
        }
        .onChange(of: selector.worktree.status) { _, status in
            guard let path = selector.worktree.statusPath, let head = status?.oid,
                  let current = app.mergeStatus.entry(for: path), head != current.entry.worktree.head else { return }
            // Only this checkout committed, so only this row needs rechecking —
            // invalidating the whole list would regroup and resize every row.
            Task { await app.mergeStatus.recheck(path: path) }
        }
        .sheet(item: $confirmation) { confirmationSheet($0) }
        .sheet(isPresented: Binding(
            get: { app.newWorktree != nil },
            set: { if !$0 { app.newWorktree = nil } }
        )) {
            if let form = app.newWorktree { NewWorktreeSheet(app: app, form: form) }
        }
    }

    @ViewBuilder
    private func confirmationSheet(_ confirmation: RemovalConfirmation) -> some View {
        switch confirmation {
        case let .worktree(worktree, action):
            let prompt = app.removalPrompt(for: worktree)
            WorktreeRemovalSheet(title: prompt.title, facts: prompt.facts, explanation: prompt.explanation,
                                 deleteBranch: prompt.offersBranchDeletion ? $app.deleteBranchOnRemove : nil,
                                 canConfirm: prompt.canRemove && action != nil && !app.groupActions.isWorking) {
                // Never anything but the captured action, through the guarded path.
                if let action {
                    app.groupActions.perform(action, deleteBranch: prompt.offersBranchDeletion && app.deleteBranchOnRemove)
                }
            }
        case let .cleanup(entries, skipped):
            WorktreeRemovalSheet(title: app.groupActions.confirmationTitle(entries),
                                 items: app.groupActions.confirmationItems(entries),
                                 facts: app.groupActions.confirmationFacts(entries) + skipped,
                                 explanation: app.groupActions.confirmationMessage(entries, deleteBranch: app.deleteBranchOnRemove),
                                 deleteBranch: $app.deleteBranchOnRemove,
                                 deleteBranchTitle: entries.count == 1 ? "Also delete the branch" : "Also delete the branches",
                                 canConfirm: !app.groupActions.isWorking) {
                app.groupActions.remove(entries, deleteBranch: app.deleteBranchOnRemove)
            }
        }
    }

    private func confirmRemoval(_ worktree: Worktree, action: WorktreeStatus.TrashAction?) {
        confirmation = .worktree(worktree, action)
    }

    private struct MergeRefreshKey: Equatable {
        let repoPath: String?
        let targetRevision: Int
        let historyRevision: Int
    }

    private var mergeRefreshKey: MergeRefreshKey {
        MergeRefreshKey(repoPath: selector.selectedRepo?.path,
                        targetRevision: app.mergeTargetRevision, historyRevision: selector.mergeRevision)
    }

    private var worktreeListBody: some View {
        VStack(spacing: 0) {
            ForEach(list.pinned) { worktreeRow($0, grouped: false) }
            ForEach(list.groups) { group in
                groupHeader(group)
                if !collapsedGroups.contains(group.kind) {
                    ForEach(group.worktrees) { worktreeRow($0, grouped: true) }
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
        let card = app.groupCard(for: group)
        return HStack(spacing: 6) {
            Button {
                if collapsed { collapsedGroups.remove(group.kind) } else { collapsedGroups.insert(group.kind) }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                        .foregroundStyle(Palette.secondaryText)
                    // System colors throughout: they are the only ones that follow light,
                    // dark and Increase Contrast, so the row of headings stays consistent.
                    // Hovered like a row's mark; the card sums the group up. The slot
                    // keeps the title in line with the row names below.
                    WorktreeMarkHoverTarget(isSelected: false, height: WorktreeListPresentation.groupHeight) {
                        WorktreeMarkView(mark: headerMark(group.kind), paused: selector.isLowPower)
                    }
                    .hoverCard(cardSummary(card)) {
                        WorktreeHoverCard(card: card, mark: headerMark(group.kind), paused: selector.isLowPower)
                    }
                    .padding(.horizontal, 3)
                    Text(group.kind.title).font(Typography.secondaryEmphasis)
                    Text("\(group.worktrees.count)").font(Typography.secondary).monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                        .padding(.leading, 7)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.kind.title), \(group.worktrees.count) worktrees")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            groupAction(group)
        }
        .padding(.horizontal, 12).frame(height: WorktreeListPresentation.groupHeight)
        .rowHighlight(isSelected: false)
    }

    /// One action per group, where there is one: the rest of the header is just a
    /// heading. The row's bin, always visible here — a cleanup you have to hover to
    /// find isn't offered.
    @ViewBuilder
    private func groupAction(_ group: WorktreeListPresentation.Group) -> some View {
        switch group.kind {
        case .merged:
            let eligible = app.groupActions.eligibleEntries(for: group.worktrees)
            if !eligible.isEmpty {
                WorktreeTrashButton(isSelected: false, label: "Remove all safe to delete worktrees", alwaysVisible: true) {
                    confirmation = .cleanup(eligible, skipped: app.groupActions.skippedFacts(for: group.worktrees))
                }
                .disabled(app.groupActions.isWorking)
                .hoverHelp("Remove the worktrees that are safe to delete.", highlight: false)
            }
        case .localChanges, .notMerged:
            EmptyView()
        }
    }

    /// The open projects, checkmark on the current one. Toggles rather than a Picker:
    /// a Picker inside a Menu draws its own divider right under the section header,
    /// while toggles become plain checked menu items straight under it.
    private var projectSwitcher: some View {
        Section("Projects") {
            ForEach(app.recentRepositories.prefix(8)) { repo in
                Toggle(isOn: Binding(
                    get: { selector.selectedRepo?.id == repo.id },
                    set: { isOn in
                        guard isOn, selector.selectedRepo?.id != repo.id else { return }
                        Task { await selector.selectRepo(repo) }
                    }
                )) {
                    Text(app.repositoryTitle(repo))
                }
            }
        }
    }

    /// Each group heading wears the mark its rows share.
    private func headerMark(_ kind: WorktreeGroup) -> WorktreeMark {
        switch kind {
        case .merged: .merged
        case .localChanges: .uncommitted
        case .notMerged: .notMerged
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
        }
        .padding(.horizontal, 11).frame(height: WorktreeListPresentation.repoHeight)
    }

    /// A card as one line of text: for accessibility, and to notice when it changes.
    private func cardSummary(_ card: WorktreeCard) -> String {
        ([card.title + ".", card.subtitle] + card.facts.map { $0.text + "." }).joined(separator: " ")
    }

    /// `grouped`: the row sits under a group heading, which carries its Git-state
    /// mark (see `WorktreeStatus.rowMark`).
    private func worktreeRow(_ worktree: Worktree, grouped: Bool) -> some View {
        let isActive = selector.selectedWorktree?.path == worktree.path
        // The mark, hover card and trash all come from here.
        let status = app.worktreeStatus(for: worktree)
        // The keyboard cursor (only while WORKTREES is the active section): an outline,
        // distinct from the filled accent of the committed worktree. Enter commits it.
        let isHighlighted = app.activeSection == .worktrees && selector.highlightedWorktree?.path == worktree.path
        let summary = cardSummary(status.card)
        return HStack(spacing: 0) {
            if status.hasHoverCard(grouped: grouped) {
                WorktreeMarkHoverTarget(isSelected: isActive) {
                    WorktreeMarkView(mark: status.rowMark(grouped: grouped), isSelected: isActive, paused: selector.isLowPower)
                }
                .hoverCard(summary) {
                    WorktreeHoverCard(card: status.card, mark: status.mark, paused: selector.isLowPower)
                }
            } else {
                // No mark to hover: the slot stays so names line up.
                Color.clear.frame(width: 22, height: WorktreeListPresentation.rowHeight)
            }
            Text(worktree.branch ?? worktree.name)
                .font(Typography.rowName)
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, 2)
                // Without a mark there is no card to hover; the text is still read out.
                .accessibilityHint(status.hasHoverCard(grouped: grouped) ? "" : summary)
            if let action = status.trashAction {
                WorktreeTrashButton(isSelected: isActive, label: "Remove worktree") {
                    confirmRemoval(worktree, action: action)
                }
                .padding(.leading, 4)
            }
            Spacer(minLength: 6)
            WorktreeSyncArrows(remote: status.remote, isSelected: isActive)
        }
        // The name starts where the Changes list's labels do.
        .padding(.leading, 24).padding(.trailing, 11).frame(height: WorktreeListPresentation.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowHighlight(isSelected: isActive)
        .foregroundStyle(isActive ? .white : .primary)
        .overlay {
            if isHighlighted, !isActive {
                RowHighlight.shape.strokeBorder(Palette.accent, lineWidth: 1.5)
                    .padding(.horizontal, RowHighlight.horizontalInset)
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
                Button("Remove Worktree…", role: .destructive) {
                    confirmRemoval(worktree, action: app.removalAction(for: worktree))
                }
                    .disabled(worktree.isLocked)
            }
        }
        .id(worktree.path)   // scroll-to target for keyboard highlight
    }
}

/// The mark's hover area: the whole mark slot at row height, so the card is easy
/// to reach. Hovering lights a soft circle behind the mark and nudges it up in
/// size straight away; the card itself follows after the hover-help delay.
private struct WorktreeMarkHoverTarget<Mark: View>: View {
    let isSelected: Bool
    /// The row's height, or the group header's.
    var height = WorktreeListPresentation.rowHeight
    @ViewBuilder var mark: () -> Mark
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        mark()
            .frame(width: 22, height: 20)
            .scaleEffect(hovered ? 1.08 : 1)
            .background {
                Circle()
                    .fill(isSelected ? Color.white.opacity(0.25) : Color(nsColor: .labelColor).opacity(0.12))
                    .frame(width: 20, height: 20)
                    .opacity(hovered ? 1 : 0)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .frame(width: 22, height: height)
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

/// The row's hover-only trash, right after the name. Muted, red under the pointer
/// (white on the selected row). `alwaysVisible`: the Safe to delete header's.
private struct WorktreeTrashButton: View {
    let isSelected: Bool
    let label: String
    var alwaysVisible = false
    let action: () -> Void
    @Environment(\.rowHovered) private var rowHovered
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash").font(.system(size: 11))
                .foregroundStyle(color)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5)
                    .fill((isSelected ? Color.white : Color.primary).opacity(hovered ? (isSelected ? 0.18 : 0.06) : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .opacity(rowHovered || alwaysVisible ? 1 : 0)
        .allowsHitTesting(rowHovered || alwaysVisible)
        .accessibilityLabel(label)
    }

    private var color: Color {
        if isSelected { return hovered ? .white : .white.opacity(0.85) }
        return hovered ? Color(nsColor: .systemRed) : Palette.secondaryText
    }
}

/// ↓behind ↑ahead against the remote copy of this same branch; nothing otherwise.
private struct WorktreeSyncArrows: View {
    let remote: RemoteSync
    let isSelected: Bool

    var body: some View {
        if case let .sameBranch(_, ahead, behind) = remote, ahead > 0 || behind > 0 {
            HStack(spacing: 5) {
                if behind > 0 { Text("↓\(behind)").foregroundStyle(isSelected ? Color.white : Color.secondary) }
                if ahead > 0 { Text("↑\(ahead)").foregroundStyle(isSelected ? Color.white : Color.primary) }
            }
            .font(Typography.secondary).monospacedDigit()
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(behind) to pull, \(ahead) to push")
        }
    }
}
