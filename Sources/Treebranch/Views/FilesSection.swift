import SwiftUI
import TreebranchCore

/// FILES accordion section: search + sort + the lazily-expanding file tree.
struct FilesSection: View {
    @Bindable var app: AppModel
    @Bindable var worktree: WorktreeModel
    @Bindable var preview: PreviewModel
    @Binding var isOpen: Bool

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "FILES", isOpen: isOpen, onToggle: { isOpen.toggle() }) {
                if isOpen {
                    Menu {
                        Picker("Sort", selection: $worktree.sortOrder) {
                            Text("Name").tag(FileSortOrder.name)
                            Text("Recently changed").tag(FileSortOrder.recent)
                        }
                        Toggle("Show ignored", isOn: $worktree.showIgnored)
                    } label: {
                        Text("···").font(.system(size: 13)).foregroundStyle(Palette.secondaryText)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
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
                    ScrollView {
                        FileRowsView(app: app, preview: preview)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .transition(.opacity)
            }
        }
        .frame(maxHeight: isOpen ? .infinity : nil)
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
    private var isSelected: Bool { worktree.selectedPath == node.path }

    var body: some View {
        HStack(spacing: 6) {
            if node.isDirectory {
                Text("▸")
                    .font(.system(size: 13)).frame(width: 13)
                    .rotationEffect(.degrees(worktree.isExpanded(node) ? 90 : 0))
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
        .animation(.easeInOut(duration: 0.18), value: isSelected)
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
        worktree.selectedPath = node.path
        worktree.selectionSource = .files
        if node.isDirectory { worktree.toggleExpand(node) }
        if preview.isVisible, !node.isDirectory, let wt = worktree.worktreePath {
            Task { await preview.update(for: node, worktreePath: wt, snapshot: worktree) }
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

    private var worktree: WorktreeModel { app.selector.worktree }

    var body: some View {
        Button("Open") { app.open(node) }
        Button("Open With…") { app.openWith(node) }
        Button("Reveal in Finder") { app.reveal(node) }
        if !node.isDirectory {
            Button("Quick Look") {
                guard let wt = worktree.worktreePath else { return }
                Task { await preview.toggle(for: node, worktreePath: wt, snapshot: worktree) }
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
