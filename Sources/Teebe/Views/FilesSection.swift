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
    /// The reveal area the tree fills below its search box. Fixed (not flexible) while
    /// browsing so a CHANGES reflow can't momentarily balloon FILES.
    var revealHeight: CGFloat
    /// While the window edge is being dragged, FILES becomes the flexible filler so the
    /// drag resizes it; otherwise it's pinned to `revealHeight`.
    var liveResizing: Bool

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
                        Text("···").font(.system(size: 13)).foregroundStyle(Palette.secondaryText).hoverChip()
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Sort & filter")
                } else if let active = app.selector.selectedWorktree {
                    Text("\(active.branch ?? active.name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if isOpen {
                VStack(spacing: 0) {
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
                        ScrollView {
                            FileRowsView(app: app, preview: preview)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        // Keep the keyboard cursor on-screen: scroll the minimal amount
                        // to reveal it when ↑/↓ moves selection past the visible edge.
                        // Snap, don't animate — an animated scrollTo fights the row's
                        // highlight animation and SwiftUI's relayout and reads as a
                        // bounce (the old row flashes before settling). Finder/Xcode
                        // snap on keyboard nav too.
                        .onChange(of: worktree.selectedPath) { _, sel in
                            guard app.activeSection == .files, let sel else { return }
                            proxy.scrollTo(sel, anchor: nil)
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        // Open + idle → a fixed reveal pane (the tree scrolls inside it), so a CHANGES
        // height change can't make FILES balloon for a frame. Open + dragging → the
        // flexible filler, so the window edge resizes the reveal. Closed → just the header.
        .frame(height: isOpen && !liveResizing ? revealHeight : nil)
        .frame(maxHeight: isOpen && liveResizing ? .infinity : nil)
        .clipped()
    }
}

/// The flat, indented file rows derived from `WorktreeModel.visibleRows`.
struct FileRowsView: View {
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel

    private var worktree: WorktreeModel { app.selector.worktree }

    var body: some View {
        if worktree.visibleRows.isEmpty {
            Text(app.repositories.isEmpty ? "Add a repository to get started" : "No files")
                .font(.system(size: 12)).foregroundStyle(Palette.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 25).padding(.vertical, 6)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(worktree.visibleRows) { row in
                    FileRow(row: row, app: app, preview: preview)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct FileRow: View {
    let row: WorktreeModel.TreeRow
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel

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
        .frame(height: 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.accent : .clear)
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
            RoundedRectangle(cornerRadius: 2)
                .fill(isSelected ? Color.white.opacity(0.9) : Color(red: 0x5A / 255, green: 0xA7 / 255, blue: 1))
                .frame(width: 15, height: 12)
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
            if node.isDirectory { worktree.toggleExpand(node) }
        }
        if preview.isVisible, !node.isDirectory, let wt = worktree.worktreePath {
            Task { await preview.update(for: node, worktreePath: wt) }
        }
    }

    private func activate() {
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
                // Resolve content AND surface the floating preview window — the
                // "preview" scene only appears via openWindow.
                Task {
                    if preview.isVisible {
                        await preview.update(for: node, worktreePath: wt)
                    } else {
                        await preview.toggle(for: node, worktreePath: wt)
                    }
                    openWindow(id: "preview")
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
