import SwiftUI
import TeebeCore

/// WORKTREES accordion section: the list of a repo's worktrees with live pulse
/// and ahead/behind sync arrows.
struct WorktreesSection: View {
    @Bindable var app: AppModel
    @Binding var isOpen: Bool

    private var selector: SelectorModel { app.selector }

    var body: some View {
        VStack(spacing: 0) {
            SectionHeader(title: "WORKTREES", isOpen: isOpen, onToggle: { isOpen.toggle() }) {
                if isOpen {
                    HStack(spacing: 2) {
                        Button { app.presentAddRepositoryPanel() } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .help("Add Repository")
                        Menu {
                            ForEach(app.repositories) { repo in
                                Button(repo.name) { Task { await selector.selectRepo(repo) } }
                            }
                            Divider()
                            Button("Add Repository…") { app.presentAddRepositoryPanel() }
                            if let selected = selector.selectedRepo {
                                Button("New Worktree…") { app.presentNewWorktreePanel() }
                                Button("Remove \(selected.name)", role: .destructive) { app.removeRepository(selected) }
                            }
                        } label: {
                            Text("···").font(.system(size: 13)).foregroundStyle(Palette.secondaryText).hoverChip()
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Repository actions")
                        Button { Task { await selector.refreshWorktreeInfo() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        }
                        .buttonStyle(IconButtonStyle()).foregroundStyle(Palette.secondaryText)
                        .help("Refresh")
                    }
                } else if let active = selector.selectedWorktree {
                    HStack(spacing: 5) {
                        LiveDot(active: selector.info(for: active).isLive)
                        Text(active.branch ?? active.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                    }
                }
            }

            if isOpen {
                // Hug the rows when there's room (so we don't grab flexible space
                // CHANGES / FILES could use), but cap at the content height and
                // scroll inside when the window is too short — the other headers
                // must never get pushed off-screen.
                ScrollView { worktreeListBody }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: listContentHeight)
                    .transition(.opacity)
            }
        }
        .clipped()
    }

    /// Estimated natural height of the worktree list, used to cap the section so it
    /// hugs its rows yet can shrink-and-scroll when space is tight.
    private var listContentHeight: CGFloat {
        let repoRow: CGFloat = selector.selectedRepo != nil ? 25 : 0
        let rows: CGFloat = selector.worktrees.isEmpty ? 26 : CGFloat(selector.worktrees.count) * 26
        return 8 + repoRow + rows   // 8 = worktreeListBody vertical padding
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
        .padding(.vertical, 4)
    }

    private func repoSubheader(_ repo: Repository) -> some View {
        HStack(spacing: 7) {
            // No disclosure triangle: there's only ever one repo root to show, so a
            // collapse affordance would be a no-op. Reintroduce it if/when the
            // workspace can hold multiple repos.
            Image(systemName: "shippingbox").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
            Text(repo.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            if let active = selector.selectedWorktree {
                Text(selector.info(for: active).syncText)
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(Palette.secondaryText)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 11).frame(height: 25)
    }

    private func worktreeRow(_ worktree: Worktree) -> some View {
        let info = selector.info(for: worktree)
        let isActive = selector.selectedWorktree?.path == worktree.path
        return HStack(spacing: 7) {
            LiveDot(active: info.isLive)
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? .white : Palette.secondaryText)
            Text(worktree.branch ?? worktree.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(info.syncText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(isActive ? .white.opacity(0.85) : Palette.secondaryText)
        }
        .padding(.leading, 25).padding(.trailing, 11).frame(height: 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Palette.accent : .clear)
        .foregroundStyle(isActive ? .white : .primary)
        .animation(.easeInOut(duration: 0.18), value: isActive)
        .contentShape(Rectangle())
        .onTapGesture { Task { await selector.selectWorktree(worktree) } }
        .contextMenu {
            Button("Open in Finder") { app.revealPath(worktree.path) }
            Button("Open in Terminal") { app.openTerminal(at: worktree.path) }
            if !worktree.isPrimary {
                Button("Remove Worktree…", role: .destructive) { app.removeWorktree(worktree) }
            }
        }
    }
}
