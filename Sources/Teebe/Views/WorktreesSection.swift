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
    @State var pendingRemoval: Worktree?
    /// The merged folders the user is being asked to confirm, captured when the
    /// header action is clicked so the list can keep changing underneath.
    @State var pendingCleanup: [CleanupEntry] = []
    /// The repository whose comparison branch is being picked in the sheet.
    @State var branchPickerRepo: Repository?

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
                            if let selected = selector.selectedRepo, app.showMergeStatus {
                                Divider()
                                Menu {
                                    comparisonMenu(selected)
                                } label: {
                                    Label("Comparison Branch", systemImage: "arrow.triangle.branch")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.secondaryText).hoverChip()
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .hoverHelp("Repository actions")
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
            guard let path = selector.worktree.statusPath, let head = status?.oid,
                  let current = app.mergeStatus.entry(for: path), head != current.entry.worktree.head else { return }
            // Only this checkout committed, so only this row needs rechecking —
            // invalidating the whole list would regroup and resize every row.
            Task { await app.mergeStatus.recheck(path: path) }
        }
        .confirmationDialog(
            app.groupActions.confirmationTitle(pendingCleanup),
            isPresented: Binding(get: { !pendingCleanup.isEmpty }, set: { if !$0 { pendingCleanup = [] } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                app.groupActions.remove(pendingCleanup)
                pendingCleanup = []
            }
            Button("Cancel", role: .cancel) { pendingCleanup = [] }
        } message: {
            Text(app.groupActions.confirmationMessage(pendingCleanup))
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
        .sheet(isPresented: Binding(
            get: { app.newWorktree != nil },
            set: { if !$0 { app.newWorktree = nil } }
        )) {
            if let form = app.newWorktree { NewWorktreeSheet(app: app, form: form) }
        }
        .sheet(item: $branchPickerRepo) { repo in
            ComparisonBranchSheet(
                branches: app.mergeStatus.snapshot?.targets.branches ?? [],
                automatic: app.mergeStatus.snapshot?.targets.automatic,
                saved: app.cleanupTarget(for: repo.path) ?? ""
            ) { ref in
                app.setCleanupTarget(ref.isEmpty ? nil : ref, for: repo.path)
            }
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
                    ForEach(group.worktrees) { worktreeRow($0, in: group.kind) }
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
        return HStack(spacing: 6) {
            Button {
                if collapsed { collapsedGroups.remove(group.kind) } else { collapsedGroups.insert(group.kind) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).frame(width: 8)
                        .foregroundStyle(Palette.secondaryText)
                    // System colors throughout: they are the only ones that follow light,
                    // dark and Increase Contrast, so the row of headings stays consistent.
                    GitStatusGlyph(group: group.kind).frame(width: 14, height: 15)
                        .foregroundStyle(headerTint(group.kind))
                    Text(group.kind.title).font(.system(size: 11, weight: .semibold))
                    Text("\(group.worktrees.count)").font(.system(size: 10)).monospacedDigit()
                        .foregroundStyle(Palette.secondaryText)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.kind.title), \(group.worktrees.count) worktrees")
            .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
            .hoverHelp(group.kind.explanation(comparedTo: comparisonBranchName))
            groupAction(group)
        }
        .padding(.horizontal, 12).frame(height: WorktreeListPresentation.groupHeight)
        .rowHighlight(isSelected: false)
    }

    /// The branch merge status was actually compared against. Group headers only
    /// exist once one resolved, so the fallback is for safety, not for display.
    private var comparisonBranchName: String {
        app.mergeStatus.snapshot?.target?.name ?? "the comparison branch"
    }

    /// One action per group, where there is one: the rest of the header is just a
    /// heading. Always visible — a cleanup you have to hover to find isn't offered.
    @ViewBuilder
    private func groupAction(_ group: WorktreeListPresentation.Group) -> some View {
        switch group.kind {
        case .merged:
            let eligible = app.groupActions.eligibleEntries(for: group.worktrees)
            if !eligible.isEmpty {
                Button("Clean up…") { pendingCleanup = eligible }
                    .buttonStyle(IconButtonStyle(size: CGSize(width: 22, height: 18))).font(.system(size: 11))
                    .foregroundStyle(Palette.accent)
                    .disabled(app.groupActions.isWorking)
                    .hoverHelp("Remove the merged worktree folders. Branches are kept.")
            }
        case .broken:
            Button("Prune") { app.groupActions.prune() }
                .buttonStyle(IconButtonStyle(size: CGSize(width: 22, height: 18))).font(.system(size: 11))
                .foregroundStyle(Palette.accent)
                .disabled(app.groupActions.isWorking)
                .hoverHelp("Forget worktrees whose folders are gone.")
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

    private func headerTint(_ kind: WorktreeGroup) -> Color {
        switch kind {
        case .merged: .green
        case .localChanges: .orange
        case .broken: .red
        case .notMerged: .secondary
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
            // One affordance when nothing resolved: the list is flat, so the ask
            // belongs here once, not on every row.
            if app.showMergeStatus, list.needsTarget { chooseComparisonBranch(repo) }
        }
        .padding(.horizontal, 11).frame(height: WorktreeListPresentation.repoHeight)
    }

    /// The comparison-branch choices. A Picker, so macOS draws the checkmark on the
    /// chosen branch itself. Lives in the ⋯ menu, and inline when nothing resolved.
    private func comparisonPicker(_ repo: Repository) -> some View {
        let saved = app.cleanupTarget(for: repo.path) ?? ""
        let targets = app.mergeStatus.snapshot?.targets
        return Picker("Comparison Branch", selection: Binding(
            get: { saved },
            set: { app.setCleanupTarget($0.isEmpty ? nil : $0, for: repo.path) }
        )) {
            Text(automaticLabel(targets?.automatic?.name)).tag("")
            ForEach(ComparisonBranchMenu.entries(targets?.branches ?? [], saved: saved)) { branch in
                Text(branch.name).tag(branch.ref)
            }
            if !saved.isEmpty, targets?.branches.contains(where: { $0.ref == saved }) != true {
                Text("Saved branch not found. Choose another.").tag(saved)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }

    /// The quick picks plus the way past them: every branch the repository has is
    /// in the sheet.
    @ViewBuilder
    private func comparisonMenu(_ repo: Repository) -> some View {
        comparisonPicker(repo)
        Divider()
        Button("Choose Comparison Branch…") { branchPickerRepo = repo }
    }

    private func chooseComparisonBranch(_ repo: Repository) -> some View {
        Menu {
            comparisonMenu(repo)
        } label: {
            Text("Choose a comparison branch…")
                .font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(Palette.accent)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Comparison branch")
        .help("Pick the branch your work is compared against.")
    }

    /// One name for the automatic choice, with the branch it actually resolved to.
    private func automaticLabel(_ name: String?) -> String {
        name.map { "Automatic (\($0))" } ?? "Automatic"
    }

    /// This checkout's merge result, live status folded in. nil when merge status
    /// is off or nothing resolved to compare against.
    private func mergeEntry(_ worktree: Worktree) -> WorktreeMergeEntry? {
        guard app.showMergeStatus, !list.needsTarget else { return nil }
        let local = selector.worktree.statusPath == worktree.path ? selector.worktree.status : nil
        return app.mergeStatus.entry(for: worktree.path, localStatus: local,
                                     localChangeCount: selector.info(for: worktree).changeCount)
    }

    /// `group` is set for the grouped rows; the pinned ones sit above the groups and
    /// carry no status of their own.
    private func worktreeRow(_ worktree: Worktree, in group: WorktreeGroup? = nil) -> some View {
        let info = selector.info(for: worktree)
        let isActive = selector.selectedWorktree?.path == worktree.path
        let entry = group == nil ? nil : mergeEntry(worktree)
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
        }
        .padding(.leading, 30).padding(.trailing, 11).frame(height: WorktreeListPresentation.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The status is a tooltip now, not a button: nothing to hover for, nothing
        // to click, and the sentence is the same one the group is named after.
        .help(group == nil ? "" : MergeIndicatorPresentation(
            status: entry, targetName: app.mergeStatus.snapshot?.target?.name,
            isChecking: app.mergeStatus.isChecking).detail)
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
                Button("Remove Worktree…", role: .destructive) { pendingRemoval = worktree }
                    .disabled(worktree.isLocked)
            }
        }
        .id(worktree.path)   // scroll-to target for keyboard highlight
    }
}

/// Picking the branch worktrees are compared against. Every ref the repository has
/// is reachable here: the handful anyone actually means first, the rest behind a
/// search field.
private struct ComparisonBranchSheet: View {
    let branches: [CleanupBranch]
    let automatic: CleanupBranch?
    let saved: String
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var focus: Field?

    private enum Field { case search, list }

    private var sections: ComparisonBranchSections {
        ComparisonBranchMenu.sections(branches, automatic: automatic, search: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Comparison Branch").font(.system(size: 15, weight: .semibold))
                Text("Worktrees are checked against this branch to decide whether they are merged.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            searchField
            branchList
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose") { choose(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection == nil)
            }
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 440, maxWidth: 640, minHeight: 520, idealHeight: 520, maxHeight: 760)
        .onAppear {
            if !saved.isEmpty || automatic != nil { selection = saved }
            focus = .search
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
            TextField("Search branches", text: $search)
                .textFieldStyle(.plain).font(.system(size: 12))
                .focused($focus, equals: .search)
                .onSubmit(chooseOnlyMatch)
                .onKeyPress(.downArrow) {
                    moveIntoList()
                    return .handled
                }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private var branchList: some View {
        let listed = sections
        return ScrollViewReader { proxy in
            List(selection: $selection) {
                if !listed.suggested.isEmpty {
                    Section("Suggested") { ForEach(listed.suggested) { branchRow($0) } }
                }
                if !listed.all.isEmpty {
                    Section("All Branches") { ForEach(listed.all) { branchRow($0) } }
                }
            }
            .listStyle(.bordered)
            .focused($focus, equals: .list)
            .overlay {
                if listed.isEmpty {
                    Text("No branches match.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .onAppear {
                guard let selection else { return }
                proxy.scrollTo(selection, anchor: .center)
            }
        }
    }

    private func branchRow(_ item: ComparisonBranchRow) -> some View {
        HStack(spacing: 8) {
            Text(item.name).font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            // Stays put while another row is highlighted, so the saved choice is
            // still readable mid-pick.
            Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                .opacity(item.id == saved ? 1 : 0)
        }
        .frame(height: 25)
        .contentShape(Rectangle())
        .opacity(item.isEnabled ? 1 : 0.4)
        .tag(item.id)
        .selectionDisabled(!item.isEnabled)
        .simultaneousGesture(TapGesture(count: 2).onEnded { choose(item.id) })
    }

    /// One match and a Return means that one, without a trip to the list.
    private func chooseOnlyMatch() {
        let visible = sections.suggested + sections.all
        guard visible.count == 1, let only = visible.first, only.isEnabled else { return }
        choose(only.id)
    }

    private func moveIntoList() {
        if selection == nil {
            selection = (sections.suggested + sections.all).first { $0.isEnabled }?.id
        }
        focus = .list
    }

    private func choose(_ ref: String?) {
        guard let ref, !ref.isEmpty || automatic != nil else { return }
        onChoose(ref)
        dismiss()
    }
}

/// Conventional Git graph: round commits joined by a branch or merge line. One
/// glyph per group, drawn at the head of its section.
struct GitStatusGlyph: View {
    let group: WorktreeGroup

    var body: some View {
        switch group {
        case .notMerged:
            Canvas { context, size in
                context.scaleBy(x: size.width / 16, y: size.height / 16)
                var lines = Path()
                lines.move(to: CGPoint(x: 4, y: 11))
                lines.addLine(to: CGPoint(x: 4, y: 2))
                lines.move(to: CGPoint(x: 1, y: 5))
                lines.addLines([CGPoint(x: 4, y: 2), CGPoint(x: 7, y: 5)])
                lines.move(to: CGPoint(x: 12, y: 5))
                lines.addLine(to: CGPoint(x: 12, y: 14))
                lines.move(to: CGPoint(x: 9, y: 11))
                lines.addLines([CGPoint(x: 12, y: 14), CGPoint(x: 15, y: 11)])
                context.stroke(lines, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                var nodes = Path()
                nodes.addEllipse(in: CGRect(x: 2, y: 11, width: 4, height: 4))
                nodes.addEllipse(in: CGRect(x: 10, y: 1, width: 4, height: 4))
                context.stroke(nodes, with: .foreground, lineWidth: 1.3)
            }
        case .broken:
            ZStack {
                Image(systemName: "folder").font(.system(size: 14))
                Image(systemName: "xmark").font(.system(size: 6, weight: .bold)).offset(y: 2)
            }
        case .merged: Image(systemName: "checkmark.circle").font(.system(size: 13, weight: .medium))
        case .localChanges: Image(systemName: "square.and.pencil").font(.system(size: 13, weight: .medium))
        }
    }
}
