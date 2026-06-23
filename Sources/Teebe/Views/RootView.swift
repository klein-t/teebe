import SwiftUI
import AppKit
import TeebeCore

/// Compact, floating main window: a three-section accordion (WORKTREES / CHANGES /
/// FILES).
struct RootView: View {
    @Bindable var app: AppModel
    @Bindable var preview: PreviewModel

    @State private var openWorktrees = true
    @State private var openChanges = true
    @State private var openFiles = true
    @State private var quickLook = QuickLookController()
    @State private var window: NSWindow?
    /// Height to restore to when a section is reopened from the fully-collapsed state.
    @State private var expandedHeight: CGFloat = 640
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    private var worktree: WorktreeModel { app.selector.worktree }

    /// Window height when all three sections are collapsed: the compact title row
    /// plus the three stacked headers (with their separators), no slack below.
    private let collapsedHeight: CGFloat = 126
    /// Comfortable height for the "no repositories" empty state.
    private let emptyStateHeight: CGFloat = 460
    /// Narrowest the window may be dragged.
    private let minWindowWidth: CGFloat = 250
    /// Shortest the window may be dragged while a section is open — always tall
    /// enough to keep all three headers visible.
    private let minWindowHeight: CGFloat = 150

    private enum Section { case worktrees, changes, files }

    private var allClosed: Bool { !openWorktrees && !openChanges && !openFiles }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            if app.repositories.isEmpty {
                emptyState
            } else {
                // Pinned-header accordion: every section header stays visible.
                // Open sections share the remaining height and scroll internally;
                // closed sections shrink to just their header. All-closed ⇒ three
                // headers stacked.
                VStack(spacing: 0) {
                    WorktreesSection(app: app, isOpen: sectionBinding(.worktrees, openWorktrees))
                    Divider()
                    ChangesSection(app: app, worktree: worktree, preview: preview, isOpen: sectionBinding(.changes, openChanges))
                    // WORKTREES and CHANGES both hug their content; only FILES fills
                    // the slack. So whenever FILES is closed, nothing claims the
                    // leftover height — push FILES to the bottom. When all are closed
                    // the headers must stay tight, so no spacer then.
                    if !openFiles && !allClosed {
                        Spacer(minLength: 0)
                    }
                    Divider()
                    FilesSection(app: app, worktree: worktree, preview: preview, isOpen: sectionBinding(.files, openFiles))
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            if let error = worktree.errorMessage ?? app.errorMessage {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.red).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 4)
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // title row sits level with the traffic lights
        .frame(minWidth: minWindowWidth, idealWidth: 440, maxWidth: .infinity,
               minHeight: lockedFrameHeight ?? minWindowHeight,
               idealHeight: lockedFrameHeight ?? 640,
               maxHeight: lockedFrameHeight ?? .infinity, alignment: .top)
        .background(.regularMaterial)
        .background(WindowController(
            floatOnTop: app.floatOnTop,
            onResolve: { resolved in
                window = resolved
                setTrafficLights(visible: false, animated: false, window: resolved)
                applyLayout(for: app.selector.selectedRepo?.path)
            },
            onLiveResizeStart: { setHeightLocked(heightLocked, height: targetHeight()) },
            onLiveResizeEnd: { handleLiveResizeEnd($0) }
        ))
        .onChange(of: app.selector.selectedRepo?.path) { _, path in applyLayout(for: path) }
        .onChange(of: app.selector.worktrees.count) { _, _ in
            if heightLocked && !allClosed { applyWindowSizing() }   // content-sized while FILES closed
        }
        .onChange(of: worktree.changeCount) { _, _ in
            if heightLocked && !allClosed { applyWindowSizing() }   // CHANGES hugs its rows
        }
        .background(QuickLookBridge(controller: quickLook))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { handleSpace(); return .handled }
        .onKeyPress(.escape) { preview.close(); dismissWindow(id: "preview"); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { activateSelected(); return .handled }
        .confirmationDialog(confirmTitle, isPresented: confirmBinding, titleVisibility: .visible) {
            Button("Confirm", role: .destructive) { Task { await worktree.confirmPendingMutation() } }
            Button("Cancel", role: .cancel) { worktree.cancelPendingMutation() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var emptyState: some View {
        EmptyStateView(app: app)
    }

    private var titleBar: some View {
        ZStack {
            Text(Brand.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
            HStack(spacing: 8) {
                Spacer()
                Button { app.floatOnTop.toggle() } label: {
                    Image(systemName: app.floatOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 13))
                        .foregroundStyle(app.floatOnTop ? Palette.accent : Palette.secondaryText)
                        .contentTransition(.symbolEffect(.replace))   // animated pin ↔ pin.fill swap
                }
                .buttonStyle(IconButtonStyle(size: CGSize(width: 26, height: 22)))
                .help("Float on top")
                .animation(.snappy(duration: 0.25), value: app.floatOnTop)
            }
            .padding(.horizontal, 11)
        }
        .frame(height: 28)
        .onHover { setTrafficLights(visible: $0, animated: true) }
    }

    /// Auto-hide the red/yellow/green window buttons until the title bar is hovered.
    private func setTrafficLights(visible: Bool, animated: Bool, window overrideWindow: NSWindow? = nil) {
        guard let window = overrideWindow ?? self.window else { return }
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }
        guard animated else {
            buttons.forEach { $0.alphaValue = visible ? 1 : 0; $0.isHidden = !visible }
            return
        }
        if visible { buttons.forEach { $0.isHidden = false } }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            buttons.forEach { $0.animator().alphaValue = visible ? 1 : 0 }
        }, completionHandler: visible ? nil : { buttons.forEach { $0.isHidden = true } })
    }

    // MARK: - Section open/close + window sizing

    /// Binding for a section's disclosure that also resizes the window across the
    /// collapsed boundary and remembers the layout for the current repo.
    private func sectionBinding(_ section: Section, _ value: Bool) -> Binding<Bool> {
        Binding(get: { value }, set: { setOpen(section, $0) })
    }

    private func setOpen(_ section: Section, _ open: Bool) {
        // Remember the free-resize height before leaving a scrollable layout.
        if heightLocked == false, let window { expandedHeight = window.frame.height }
        // Snap the content state — the *window* owns the open/close motion (see
        // applyWindowSizing). Animating the content here would race the window's
        // content-pinned min-size and bounce.
        switch section {
        case .worktrees: openWorktrees = open
        case .changes: openChanges = open
        case .files: openFiles = open
        }
        applyWindowSizing()
        persistLayout()
    }

    /// Restore a repo's remembered layout (or sensible defaults) and size the
    /// window to match. Called when the window first resolves and whenever the
    /// selected repository changes.
    private func applyLayout(for repoPath: String?) {
        guard let repoPath else {
            setHeightLocked(false, height: emptyStateHeight)
            setWindowHeight(emptyStateHeight, animated: false)   // no project → empty state
            return
        }
        let layout = app.layout(forRepo: repoPath) ?? SectionLayout()   // default: all open, 640
        openWorktrees = layout.worktreesOpen
        openChanges = layout.changesOpen
        openFiles = layout.filesOpen
        expandedHeight = max(CGFloat(layout.windowHeight), minWindowHeight)
        applyWindowSizing(animated: false)
    }

    /// `true` when FILES (the only space-filling section) is closed — WORKTREES and
    /// CHANGES both hug their rows, so the window is sized to its content and its
    /// height is pinned (width stays free).
    private var heightLocked: Bool { !openFiles }

    /// When no scrollable section is open the window is content-pinned: drive the
    /// SwiftUI frame to that exact height so `windowResizability` reports the same
    /// min/ideal/max we set on the `NSWindow`. Otherwise SwiftUI's content-min
    /// re-clamps the window a frame later and leaves an empty "chin" below the
    /// last header.
    ///
    /// `targetHeight()` is a *window* height; SwiftUI's `.frame` sizes the
    /// *content* (`contentLayoutRect`) and the window is that plus a constant
    /// title-bar inset. We draw the title row into that inset (`ignoresSafeArea`),
    /// so subtract it here — otherwise the window ends up one title-bar taller than
    /// the target and the surplus shows as the chin.
    private var lockedFrameHeight: CGFloat? {
        guard heightLocked else { return nil }
        let inset = window.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        return max(targetHeight() - inset, 0)
    }

    /// The height the window should be for the current open/closed state.
    private func targetHeight() -> CGFloat {
        if allClosed { return collapsedHeight }
        if heightLocked {                                   // FILES closed → hug content
            let cap = (window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
            return min(collapsedHeight + worktreesContentHeight + changesContentHeight + 4, cap)
        }
        return expandedHeight                               // FILES open → free height
    }

    /// Estimated natural height of the open worktree list (mirrors WorktreesSection).
    private var worktreesContentHeight: CGFloat {
        guard openWorktrees else { return 0 }
        let s = app.selector
        let repoRow: CGFloat = s.selectedRepo != nil ? 25 : 0
        let rows: CGFloat = s.worktrees.isEmpty ? 26 : CGFloat(s.worktrees.count) * 26
        return 8 + repoRow + rows
    }

    /// Estimated natural height of the open change list (mirrors ChangesSection:
    /// 24pt rows plus the section's 8pt top / 6pt bottom padding).
    private var changesContentHeight: CGFloat {
        guard openChanges else { return 0 }
        let count = app.selector.worktree.changeCount
        return 14 + (count == 0 ? 24 : CGFloat(count) * 24)
    }

    /// Size the window to the current state and lock/free its height accordingly.
    private func applyWindowSizing(animated: Bool = true) {
        guard let window else { return }
        let target = targetHeight()
        setHeightLocked(heightLocked, height: target)
        // Animate only a grow into a *free* (scrollable) layout — the window glides
        // open to reveal CHANGES / FILES. Everything else snaps:
        //  • Shrinks snap, or the top-anchored content flashes an empty "chin" while
        //    the window lags behind the collapsed headers.
        //  • Height-locked states are content-pinned (windowResizability is
        //    .contentMinSize), so an animated frame races the content's min-size and
        //    bounces. Snapping keeps the window and content in lockstep.
        let shrinking = target < window.frame.height
        setWindowHeight(target, animated: animated && !shrinking && !heightLocked)
    }

    /// User finished dragging the window edge → remember the new height, but only
    /// while a scrollable section is open (otherwise height is content-pinned).
    private func handleLiveResizeEnd(_ height: CGFloat) {
        guard !heightLocked else { return }
        expandedHeight = height
        persistLayout()
    }

    private func persistLayout() {
        guard let repo = app.selector.selectedRepo?.path else { return }
        let height = heightLocked ? expandedHeight : (window?.frame.height ?? expandedHeight)
        app.saveLayout(
            SectionLayout(
                worktreesOpen: openWorktrees,
                changesOpen: openChanges,
                filesOpen: openFiles,
                windowHeight: Double(height)
            ),
            forRepo: repo
        )
    }

    /// Resize the window to `height`, keeping the top edge pinned so it grows and
    /// shrinks downward.
    private func setWindowHeight(_ height: CGFloat, animated: Bool = true) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - height
        frame.size.height = height
        window.setFrame(frame, display: true, animate: animated)
    }

    /// Pin the window *height* (content-sized when locked) while keeping width
    /// freely resizable. Re-asserted on every resize-drag start.
    private func setHeightLocked(_ locked: Bool, height: CGFloat) {
        guard let window else { return }
        window.minSize = NSSize(width: minWindowWidth, height: locked ? height : minWindowHeight)
        window.maxSize = NSSize(width: 100_000, height: locked ? height : 100_000)
    }

    // MARK: - Keyboard

    private func move(_ delta: Int) {
        worktree.selectionSource = .files
        delta < 0 ? worktree.selectPrevious() : worktree.selectNext()
        if preview.isVisible, let node = worktree.selectedNode, !node.isDirectory,
           let wt = worktree.worktreePath {
            Task { await preview.update(for: node, worktreePath: wt) }
        }
    }

    /// Spacebar previews the current selection: the native Quick Look panel for a
    /// FILES row, or the in-app diff peek for a CHANGES row.
    private func handleSpace() {
        switch worktree.selectionSource {
        case .changes: toggleDiffPeek()
        case .files: presentQuickLook()
        }
    }

    private var selectedChange: FileChange? {
        guard let sel = worktree.selectedPath, let wt = worktree.worktreePath else { return nil }
        let relative = PathUtil.relativePath(of: sel, under: PathUtil.standardized(wt))
        return worktree.changes.first { $0.path == relative }
    }

    /// Toggle the floating diff preview for the selected change (CHANGES spacebar).
    private func toggleDiffPeek() {
        if preview.isVisible {
            preview.close()
            dismissWindow(id: "preview")
            return
        }
        guard let wt = worktree.worktreePath, let change = selectedChange else { return }
        let node = FileNode(path: wt + "/" + change.path, isDirectory: false, change: change)
        Task {
            await preview.toggle(for: node, worktreePath: wt)
            openWindow(id: "preview")
        }
    }

    /// Spacebar → the native macOS Quick Look panel (Finder-style). Hands the panel
    /// every visible file so its arrow keys page through them, starting on the
    /// current selection.
    private func presentQuickLook() {
        let files = worktree.visibleRows.filter { !$0.node.isDirectory }
        guard !files.isEmpty else { return }
        let urls = files.map { URL(fileURLWithPath: $0.node.path) }
        let start = worktree.selectedPath.flatMap { sel in files.firstIndex { $0.node.path == sel } } ?? 0
        quickLook.toggle(urls: urls, startIndex: start)
    }

    private func activateSelected() {
        guard let node = worktree.selectedNode else { return }
        if node.isDirectory { worktree.toggleExpand(node) } else { app.open(node) }
    }

    // MARK: - Guarded mutation confirmation

    private var confirmBinding: Binding<Bool> {
        Binding(
            get: { worktree.pendingMutation != nil },
            set: { if !$0 { worktree.cancelPendingMutation() } }
        )
    }

    private var confirmTitle: String {
        switch worktree.pendingMutation?.kind {
        case .discard, .discardUntracked: return "Discard changes?"
        case .trash: return "Move to Trash?"
        case .none: return ""
        }
    }

    private var confirmMessage: String {
        guard let mutation = worktree.pendingMutation else { return "" }
        var lines = mutation.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if lines.isEmpty { lines = "the worktree" }
        let busy = mutation.worktreeBusy ? "\n⚠︎ This worktree was written to recently (an agent may be active)." : ""
        return "Affects: \(lines)\(busy)"
    }
}

/// The "no repositories" hero. Its four chunks fade/rise/de-blur in sequence on
/// appear (split-and-stagger enter) instead of popping in as one block.
private struct EmptyStateView: View {
    @Bindable var app: AppModel
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 14) {
            logo
                .modifier(StaggeredReveal(revealed: revealed, step: 0))
            Text("No repositories yet")
                .font(.headline)
                .modifier(StaggeredReveal(revealed: revealed, step: 1))
            Text("Add a git repository to browse its worktrees,\nchanges, and files.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .modifier(StaggeredReveal(revealed: revealed, step: 2))
            Button {
                app.presentAddRepositoryPanel()
            } label: {
                Label("Add Repository…", systemImage: "plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .modifier(StaggeredReveal(revealed: revealed, step: 3))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(40)
        .onAppear { revealed = true }
    }

    @ViewBuilder
    private var logo: some View {
        if let logo = Brand.logo {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 84, height: 84)
        } else {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 38))
                .foregroundStyle(Palette.secondaryText)
        }
    }
}

/// One chunk of a staggered enter: opacity + a small rise + a 4pt deblur, each
/// chunk delayed `step × 90ms`. Matches the skill's split-and-stagger pattern
/// (translateY/opacity/blur) without a motion dependency.
private struct StaggeredReveal: ViewModifier {
    let revealed: Bool
    let step: Int

    func body(content: Content) -> some View {
        content
            .opacity(revealed ? 1 : 0)
            .offset(y: revealed ? 0 : 10)
            .blur(radius: revealed ? 0 : 4)
            .animation(.smooth(duration: 0.5).delay(Double(step) * 0.09), value: revealed)
    }
}
