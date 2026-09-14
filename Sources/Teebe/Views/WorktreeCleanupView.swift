import SwiftUI
import TeebeCore

struct WorktreeCleanupView: View {
    @State private var model: WorktreeCleanupModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, repo: Repository) {
        _model = State(initialValue: WorktreeCleanupModel(app: app, repo: repo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            targetControls
            Divider()
            worktreeList
            notices
            Divider()
            footer
        }
        .frame(width: 620, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.refresh() }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.isRemoving)
        .confirmationDialog(
            "Remove \(model.pendingRemoval?.entries.count ?? 0) worktree folders?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Worktrees", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let plan = model.pendingRemoval { Text(confirmationText(plan)) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clean up worktrees").font(.title3.weight(.semibold))
            Spacer()
            Text(model.repo.name).foregroundStyle(.secondary).lineLimit(1).help(model.repo.path)
        }
        .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
    }

    private var targetControls: some View {
        HStack(spacing: 8) {
            Picker("Merge target", selection: Binding(
                get: { model.targetOverride },
                set: { ref in Task { await model.chooseTarget(ref) } }
            )) {
                Text(model.automaticLabel).tag("")
                ForEach(model.targets.branches) { branch in Text(branch.name).tag(branch.ref) }
                if !model.targetOverride.isEmpty, !model.targets.branches.contains(where: { $0.ref == model.targetOverride }) {
                    Text("Saved branch unavailable").tag(model.targetOverride)
                }
            }
            .frame(maxWidth: 440, alignment: .leading).disabled(model.isBusy)
            .help("Automatic uses Git's recorded default branch. Choose dev or another branch if that is where you merge your work.")
            Spacer(minLength: 0)
            Button { Task { await model.refresh() } } label: {
                Image(systemName: "arrow.clockwise").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless).disabled(model.isBusy)
            .accessibilityLabel("Recheck worktrees")
            .help(model.snapshot.map { "Recheck local history. Last checked \($0.checkedAt.formatted(date: .omitted, time: .shortened))." }
                  ?? "Recheck local Git history")
            Menu {
                Button("Fetch & recheck") { Task { await model.refresh(fetch: true) } }
                Divider()
                Toggle("Merged only", isOn: $model.mergedOnly)
                if model.entries.contains(where: \.hasIgnoredFiles) {
                    Toggle("Include ignored files in removal", isOn: $model.includeIgnored)
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .disabled(model.isBusy).accessibilityLabel("Cleanup options")
            .help("Fetch remote history, filter worktrees, or include ignored files")
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var worktreeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.isBusy {
                    ProgressView(model.isRemoving ? "Rechecking and removing…" : "Checking worktrees…")
                        .controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 50)
                } else if model.snapshot != nil, model.snapshot?.target == nil {
                    emptyState("Choose a merge target", detail: "Select the branch your work merges into.")
                } else if model.visibleEntries.isEmpty {
                    emptyState(model.mergedOnly ? "No confirmed merged worktrees" : "No worktrees to show",
                               detail: model.mergedOnly ? "Show all worktrees from the options menu." : "Linked worktrees will appear here.")
                } else {
                    let merged = model.visibleEntries.filter { $0.mergeStatus == .merged }
                    let unconfirmed = model.visibleEntries.filter { $0.mergeStatus != .merged }
                    if !merged.isEmpty {
                        groupHeader("Merged into \(model.snapshot?.target?.name ?? "target")", canSelect: true)
                        ForEach(merged) { cleanupRow($0) }
                    }
                    if !unconfirmed.isEmpty {
                        groupHeader("Merge not confirmed", canSelect: false)
                            .help("Git has not confirmed these commits in the target. Squash merges can contain the changes without preserving the original commits.")
                        ForEach(unconfirmed) { cleanupRow($0) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func groupHeader(_ title: String, canSelect: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if canSelect {
                Button(model.selectedPaths.isEmpty ? "Select eligible" : "Clear selection") {
                    if model.selectedPaths.isEmpty { model.selectEligible() } else { model.selectedPaths.removeAll() }
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                .disabled(model.isBusy || model.eligibleEntries.isEmpty)
            }
        }
        .padding(.horizontal, 20).frame(height: 32)
    }

    private func cleanupRow(_ entry: CleanupEntry) -> some View {
        let blocker = model.blocker(for: entry)
        return HStack(spacing: 5) {
            if blocker == nil {
                Toggle(isOn: Binding(
                    get: { model.selectedPaths.contains(entry.id) },
                    set: { selected in
                        if selected { model.selectedPaths.insert(entry.id) } else { model.selectedPaths.remove(entry.id) }
                    }
                )) { rowLabel(entry, blocker: nil) }
                .toggleStyle(.checkbox).disabled(model.isBusy)
                .accessibilityLabel("Select \(entry.worktree.branch ?? entry.worktree.name)")
            } else {
                Color.clear.frame(width: 16, height: 16).accessibilityHidden(true)
                rowLabel(entry, blocker: blocker)
            }
        }
        .padding(.horizontal, 20).frame(minHeight: 36)
        .background(Palette.accent.opacity(model.selectedPaths.contains(entry.id) ? 0.08 : 0))
        .rowHighlight(isSelected: false)
    }

    private func rowLabel(_ entry: CleanupEntry, blocker: String?) -> some View {
        HStack(spacing: 12) {
            Text(entry.worktree.branch ?? entry.worktree.name)
                .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(entry.worktree.path)
            Spacer(minLength: 0)
            if let blocker, blocker != "Merge not confirmed" {
                Text(shortReason(blocker)).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).help(blocker)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func shortReason(_ reason: String) -> String {
        switch reason {
        case "Has local changes or untracked files": return "Local changes"
        case "Contains ignored files": return "Ignored files"
        case "Some files are excluded from Git checks": return "Files excluded from checks"
        default: return reason
        }
    }

    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.includeIgnored {
                Text("Removal includes ignored files, such as build output and local settings.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let message = model.resultMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                ScrollView {
                    Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(maxHeight: 60)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack {
            Text("Branches are kept.").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isRemoving)
            Button(model.selectedEntries.isEmpty ? "Remove…" : "Remove \(model.selectedEntries.count)…", role: .destructive) {
                model.requestRemoval()
            }
            .disabled(model.isBusy || model.selectedEntries.isEmpty)
            .monospacedDigit()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func confirmationText(_ plan: WorktreeCleanupModel.RemovalPlan) -> String {
        var text = "The selected folders will be deleted from your Mac. Branches will be kept. Each worktree will be checked again before removal."
        if plan.includingIgnored { text += " Ignored files inside those folders will also be deleted." }
        text += "\n\n" + plan.entries.prefix(5).map { $0.worktree.branch ?? $0.worktree.name }.joined(separator: "\n")
        if plan.entries.count > 5 { text += "\nAnd \(plan.entries.count - 5) more." }
        return text
    }
}
