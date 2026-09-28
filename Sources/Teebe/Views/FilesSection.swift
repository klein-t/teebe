import SwiftUI
import AppKit
import TeebeCore

/// FILES accordion section: search + sort + the lazily-expanding file tree.
struct FilesSection: View {
    @Bindable var app: AppModel
    @Bindable var worktree: WorktreeModel
    @Bindable var preview: PreviewModel
    @Binding var isOpen: Bool
    /// Owned by RootView; lets ⌘F focus the search field and ↓/Esc hand focus back.
    var searchFocused: FocusState<Bool>.Binding
    /// The reveal area below the section header (search box + tree). Fixed (not
    /// flexible) while browsing so a CHANGES reflow can't momentarily balloon FILES.
    var revealHeight: CGFloat
    /// While the window edge is being dragged, FILES becomes the flexible filler so the
    /// drag resizes it; otherwise it's pinned to `revealHeight`.
    var liveResizing: Bool
    /// The open folders pinned over the top of the tree while it is scrolled.
    @State private var sticky = StickyFolders()

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "FILES", isOpen: isOpen, isActive: app.activeSection == .files, onToggle: { isOpen.toggle() }) {
                if isOpen {
                    Menu {
                        Picker("Show", selection: $worktree.filter) {
                            Text("All files").tag(ChangeFilter.all)
                            Text("Changed only").tag(ChangeFilter.changed)
                        }
                        Picker("Sort", selection: $worktree.sortOrder) {
                            Text("Name").tag(FileSortOrder.name)
                            Text("Recently changed").tag(FileSortOrder.recent)
                        }
                        Toggle("Show ignored", isOn: $worktree.showIgnored)
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Palette.secondaryText).hoverChip()
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .hoverHelp("Sort & filter")
                }
            }

            if isOpen {
                VStack(spacing: 0) {
                    if worktree.isFolderMissing {
                        MissingFolderPlaceholder(isKept: worktree.worktreePath.map(app.selector.keptMissingPaths.contains) ?? false) {
                            guard let path = worktree.worktreePath else { return }
                            Task { await app.selector.forgetMissingWorktree(path) }
                        }
                        Spacer(minLength: 0)
                    } else {
                        TextField("Search files", text: $worktree.searchQuery)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .focused(searchFocused)
                            .onChange(of: app.searchFocusRequest) { _, _ in searchFocused.wrappedValue = true }
                            // ↓ drops focus into the results so the tree's arrow keys take over.
                            .onKeyPress(.downArrow) {
                                searchFocused.wrappedValue = false
                                if let first = worktree.visibleRows.first,
                                   worktree.selectedPath == nil
                                    || !worktree.visibleRows.contains(where: { $0.node.path == worktree.selectedPath }) {
                                    worktree.select(first.node.path)
                                }
                                return .handled
                            }
                            // Enter opens the current (or first) result without leaving the field.
                            .onKeyPress(.return) {
                                guard let node = worktree.selectedNode ?? worktree.visibleRows.first?.node else { return .ignored }
                                if node.isDirectory { worktree.toggleExpand(node) } else { app.open(node) }
                                return .handled
                            }
                            // Esc clears the query first, then hands focus back to the tree.
                            .onKeyPress(.escape) {
                                if worktree.searchQuery.isEmpty { searchFocused.wrappedValue = false } else { worktree.searchQuery = "" }
                                return .handled
                            }
                        ScrollViewReader { proxy in
                            // Rows fade into the window's bottom edge while more are below,
                            // like the WORKTREES and CHANGES lists.
                            BottomFadingScrollView {
                                FileRowsView(app: app, preview: preview, sticky: sticky)
                                    // The open folders above the first visible row stay pinned
                                    // over the top of the list. They ride in the scrolled content,
                                    // so the scroll bar stays above them and the wheel scrolls
                                    // through them; the bottom fade never reaches them.
                                    .overlay(alignment: .top) {
                                        StickyFolderStack(sticky: sticky, app: app, preview: preview) { reveal($0, proxy: proxy) }
                                    }
                            } onScrollOffsetChange: { sticky.update(scrollOffset: $0) }
                            .scrollBounceBehavior(.basedOnSize)
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.onChange(of: geometry.size.height, initial: true) { _, height in
                                        sticky.update(viewportHeight: height)
                                    }
                                }
                            }
                            // Keep the keyboard cursor on-screen: scroll the minimal amount
                            // to reveal it when ↑/↓ moves selection past the visible edge,
                            // and never leave it under the pinned folders.
                            // Snap, don't animate — an animated scrollTo fights the row's
                            // highlight animation and SwiftUI's relayout and reads as a
                            // bounce (the old row flashes before settling). Finder/Xcode
                            // snap on keyboard nav too.
                            .onChange(of: worktree.selectedPath) { _, sel in
                                guard app.activeSection == .files, let sel else { return }
                                reveal(sel, proxy: proxy)
                            }
                        }
                    }
                }
                // Idle → a fixed reveal pane (the tree scrolls inside it), so a CHANGES
                // reflow can't make FILES balloon for a frame. Dragging → the flexible
                // filler, so the window edge resizes the reveal. The frame sits on the
                // search+tree content, NOT the whole section: `revealHeight` is the area
                // *below* the header (RootView budgets the header separately in
                // `collapsedHeight`), so pinning the outer VStack — header included —
                // rendered the section one header-height short and left a dead strip of
                // empty material at the window's bottom edge.
                .frame(height: liveResizing ? nil : revealHeight)
                .frame(maxHeight: liveResizing ? .infinity : nil)
                .transition(.opacity)
            }
        }
        .frame(maxHeight: isOpen && liveResizing ? .infinity : nil)
        .clipped()
    }

    /// Scroll `path`'s row into view: the minimal scroll, unless that would leave it
    /// under the pinned folders, in which case it lands just below them.
    private func reveal(_ path: String, proxy: ScrollViewProxy) {
        if let anchor = sticky.revealAnchor(for: path) {
            proxy.scrollTo(anchor, anchor: .top)
        } else {
            proxy.scrollTo(path, anchor: nil)
        }
    }
}

/// Stands in for the file list when the selected worktree's folder is gone, in the
/// moment before Teebe cleans it up: a calm explanation and a way to forget just
/// this worktree, instead of an empty tree and an error. A record that still
/// holds work (`isKept`) is never forgotten, so it has no Forget.
struct MissingFolderPlaceholder: View {
    var isKept = false
    let onForget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This worktree's folder is gone.", systemImage: "folder.badge.questionmark")
                .font(Typography.bodyEmphasis)
            Text(isKept ? "Git’s record of it holds commits or staged changes no branch has, so Teebe keeps it. "
                    + "Restore the folder, or put that work on a branch, to keep it."
                    : "It was moved or deleted. Forget clears Git’s record of it; the branch is kept.")
                .font(Typography.secondary).foregroundStyle(Palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !isKept {
                Button("Forget", action: onForget)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30).padding(.vertical, 12)
    }
}

/// The flat, indented file rows derived from `WorktreeModel.visibleRows`.
struct FileRowsView: View {
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel
    /// Works out the pinned folders from the same rows.
    let sticky: StickyFolders

    private var worktree: WorktreeModel { app.selector.worktree }

    var body: some View {
        let rows = worktree.visibleRows
        Group {
            if rows.isEmpty {
                Text(app.repositories.isEmpty ? "Add a repository to get started" : "No files")
                    .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 30).padding(.vertical, 6)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        FileRow(row: row, app: app, preview: preview)
                    }
                }
                .padding(.vertical, StickyFolders.topInset)
            }
        }
        .onChange(of: rows, initial: true) { _, rows in sticky.update(rows: rows) }
    }
}

/// Copies of the open folders' rows, pinned over the top of the FILES tree while it
/// is scrolled, outermost first. The innermost slides up under the one above it as
/// its folder's contents run out.
struct StickyFolderStack: View {
    let sticky: StickyFolders
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel
    /// Brings a folder's real row into view, just below its own pinned folders.
    let reveal: (String) -> Void

    var body: some View {
        // Laid out over the whole content: its top edge is `offset` above the
        // viewport's, so moving the stack down by that much pins it to the viewport
        // in the same layout pass as the scroll, never a frame behind it.
        GeometryReader { geometry in
            let offset = -geometry.frame(in: .scrollView).minY
            let pinned = sticky.pinned(at: offset)
            if !pinned.rows.isEmpty {
                PinnedFolderRows(rows: pinned.rows, pushOffset: pinned.pushOffset, app: app, preview: preview, reveal: reveal)
                    // Most scroll frames pin the same rows: skip rebuilding them.
                    .equatable()
                    .offset(y: offset)
            }
        }
    }
}

/// The pinned folders' rows, stacked: the innermost is drawn under the rest and
/// pushed up by `pushOffset`, with a soft edge under the whole stack.
struct PinnedFolderRows: View, Equatable {
    let rows: [WorktreeModel.TreeRow]
    let pushOffset: CGFloat
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel
    let reveal: (String) -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var worktree: WorktreeModel { app.selector.worktree }

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rows == rhs.rows && lhs.pushOffset == rhs.pushOffset
    }

    var body: some View {
        let rowHeight = StickyFolders.rowHeight
        ZStack(alignment: .top) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { level, row in
                FileRow(row: row, app: app, preview: preview, pinned: actions(for: row.node))
                    .background(listBackground)
                    .offset(y: CGFloat(level) * rowHeight + (level == rows.count - 1 ? pushOffset : 0))
                    .zIndex(-Double(level))
            }
        }
        .frame(height: CGFloat(rows.count) * rowHeight + pushOffset, alignment: .top)
        .clipped()
        .overlay(alignment: .bottom) {
            // A soft edge under the stack only, as the rows slip beneath it.
            LinearGradient(colors: [Self.edgeShadow, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 3)
                .offset(y: 3)
                .allowsHitTesting(false)
        }
    }

    private func actions(for node: FileNode) -> FileRow.PinnedActions {
        FileRow.PinnedActions(
            reveal: { reveal(node.path) },
            collapse: {
                app.activeSection = .files
                worktree.select(node.path)
                // Park the folder just below its own pinned folders, then fold it:
                // the rows above it stay where they are, so the list doesn't jump.
                reveal(node.path)
                if worktree.isExpanded(node) { worktree.toggleExpand(node) }
            })
    }

    /// The list's own color, opaque, so rows scrolling underneath never show through:
    /// the window's material as it renders there, flattened. A live material here
    /// would blur the rows under it again on every scroll frame. With Reduce
    /// Transparency the material is solid already, so it is used as is.
    @ViewBuilder private var listBackground: some View {
        if reduceTransparency {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Rectangle().fill(.regularMaterial)
            }
        } else {
            Self.flattenedMaterial
        }
    }

    private static let flattenedMaterial = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 43 / 255 : 235 / 255, alpha: 1)
    })

    private static let edgeShadow = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(white: 0, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.28 : 0.07)
    })
}

struct FileRow: View {
    let row: WorktreeModel.TreeRow
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel
    /// Set on a copy of a folder's row pinned over the top of the tree.
    var pinned: PinnedActions?

    /// What a pinned copy of a folder's row does: a click brings the real row into
    /// view instead of folding it, and only the chevron folds the folder.
    struct PinnedActions {
        let reveal: () -> Void
        let collapse: () -> Void
    }

    private var worktree: WorktreeModel { app.selector.worktree }
    private var node: FileNode { row.node }
    private var isSelected: Bool { app.activeSection == .files && worktree.selectedPaths.contains(node.path) }
    private var isExpanded: Bool { worktree.isExpanded(node) }

    var body: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold)).frame(width: 13, height: 13)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0), anchor: .center)
                    // Short constant-speed flip, hard stop — no spring, no ease-out
                    // settle (which read as a "bounce" on the lone moving element).
                    .animation(.linear(duration: 0.1), value: isExpanded)
                    .foregroundStyle(isSelected ? .white : Palette.secondaryText)
                    .contentShape(Rectangle())
                    .onTapGesture { pinned?.collapse() }
                    .allowsHitTesting(pinned != nil)
            } else {
                Spacer().frame(width: 13)
            }
            icon
            Text(node.name)
                .font(.system(size: 13)).lineLimit(1)
            Spacer(minLength: 4)
            if let change = node.change {
                StatusLetter(change: change)
            } else if node.containsChanges {
                Circle().fill(Palette.amber).frame(width: 6, height: 6)
            }
        }
        .padding(.leading, CGFloat(row.depth) * 16 + 11).padding(.trailing, 11)
        .frame(height: StickyFolders.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowHighlight(isSelected: isSelected)
        .foregroundStyle(isSelected ? .white : .primary)
        // No fade on selection: a 0.18s cross-fade leaves a visible trail of
        // half-lit rows when arrowing fast. The cursor snaps, like native file lists.
        .contentShape(Rectangle())
        .onTapGesture { select() }
        .simultaneousGesture(TapGesture(count: 2).onEnded { activate() })
        .contextMenu { FileContextMenu(node: node, app: app, preview: preview) }
    }

    @ViewBuilder
    private var icon: some View {
        if node.isDirectory {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white : Color(red: 0x5A / 255, green: 0xA7 / 255, blue: 1))
                .frame(width: 15)
        } else {
            Image(systemName: node.iconName)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .white : Palette.secondaryText)
                .frame(width: 15)
        }
    }

    private func select() {
        // ⌘-click toggles one row; ⇧-click extends a range; a plain click single-selects
        // (and toggles a folder's expansion).
        app.activeSection = .files
        let mods = NSEvent.modifierFlags
        if mods.contains(.command) {
            worktree.toggleSelection(node.path)
        } else if mods.contains(.shift) {
            worktree.extendSelection(to: node.path)
        } else {
            worktree.select(node.path)
            if let pinned { pinned.reveal() } else if node.isDirectory { worktree.toggleExpand(node) }
        }
        if preview.isVisible, !node.isDirectory, let wt = worktree.worktreePath {
            Task { await preview.update(for: node, worktreePath: wt) }
        }
    }

    private func activate() {
        guard pinned == nil else { return }
        if node.isDirectory { worktree.toggleExpand(node) } else { app.open(node) }
    }
}

/// Shared file-row context menu (PRD §7).
struct FileContextMenu: View {
    let node: FileNode
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel
    @Environment(\.openWindow) private var openWindow

    private var worktree: WorktreeModel { app.selector.worktree }

    var body: some View {
        Button("Open") { app.open(node) }
        Button("Open With…") { app.openWith(node) }
        Button("Reveal in Finder") { app.reveal(node) }
        if !node.isDirectory {
            Button("Quick Look") {
                guard let wt = worktree.worktreePath else { return }
                // Show the window before loading so a close during loading stays closed.
                Task {
                    openWindow(id: "preview")
                    if preview.isVisible {
                        await preview.update(for: node, worktreePath: wt)
                    } else {
                        await preview.toggle(for: node, worktreePath: wt)
                    }
                }
            }
        }
        Divider()
        Button("New File…") { app.newFile(in: node) }
        Button("New Folder…") { app.newFolder(in: node) }
        Button("Rename…") { app.rename(node) }
        Button("Duplicate") { app.duplicate(node) }
        Button("Copy Path") { app.copyPath(node) }
        if let change = node.change {
            Divider()
            if change.isStaged {
                Button("Unstage") { Task { await worktree.unstage(change) } }
            } else {
                Button("Stage") { Task { await worktree.stage(change) } }
            }
            Button("Discard…", role: .destructive) { worktree.requestDiscard(change) }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { worktree.requestTrash(path: node.path) }
    }
}
