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
        // Sized, not pinned: the main window can be as narrow as 250pt, and a hard frame
        // that wide simply overflowed it.
        .frame(minWidth: 480, idealWidth: 620, minHeight: 380, idealHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await model.load() }
        .onDisappear { model.cancel() }
        .interactiveDismissDisabled(model.isRemoving)
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(model.pendingRemoval?.entries.count == 1 ? "Remove Worktree" : "Remove Worktrees",
                   role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.pendingRemoval = nil }
        } message: {
            if let plan = model.pendingRemoval { Text(confirmationText(plan)) }
        }
    }

    private var removalTitle: String {
        let count = model.pendingRemoval?.entries.count ?? 0
        return count == 1 ? "Remove this worktree folder?" : "Remove \(count) worktree folders?"
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
            Picker("Comparison branch", selection: Binding(
                get: { model.targetOverride },
                set: { ref in Task { await model.chooseTarget(ref) } }
            )) {
                Text(model.automaticLabel).tag("")
                ForEach(model.targets.branches) { branch in Text(branch.name).tag(branch.ref) }
                if !model.targetOverride.isEmpty, !model.targets.branches.contains(where: { $0.ref == model.targetOverride }) {
                    Text("Saved branch not found. Choose another.").tag(model.targetOverride)
                }
            }
            .frame(maxWidth: 440, alignment: .leading).disabled(model.isBusy)
            .help("Uses the repository's default branch.")
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
                if model.snapshot != nil, model.snapshot?.target == nil {
                    emptyState("Choose a comparison branch", detail: "Select the branch your work merges into.")
                } else if model.visibleEntries.isEmpty {
                    mergedOnlyEmptyState
                } else {
                    let merged = model.visibleEntries.filter { $0.mergeStatus == .merged }
                    let unmerged = model.visibleEntries.filter { $0.mergeStatus != .merged }
                    if !merged.isEmpty {
                        groupHeader("\(WorktreeGroup.merged.title) into \(model.snapshot?.target?.name ?? "target")",
                                    canSelect: true)
                        ForEach(merged) { cleanupRow($0) }
                    }
                    if !unmerged.isEmpty {
                        groupHeader(WorktreeGroup.notMerged.title, canSelect: false)
                            .help("Commits not found in \(model.snapshot?.target?.name ?? "the comparison branch").")
                        ForEach(unmerged) { cleanupRow($0) }
                    }
                }
            }
            .padding(.vertical, 8)
            // The previous results stay put while a recheck runs: dimmed and inert, so
            // the user keeps their place instead of watching the list vanish.
            .opacity(model.isChecking ? 0.4 : 1)
            .disabled(model.isChecking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Nothing to show because the list is filtered: the control that changes that is
    /// right here, rather than a sentence pointing at a menu.
    private var mergedOnlyEmptyState: some View {
        VStack(spacing: 6) {
            Text(model.mergedOnly ? "No merged worktrees" : "No worktrees to show")
                .font(.callout.weight(.medium))
            if model.mergedOnly {
                Button("Show All Worktrees") { model.mergedOnly = false }
            } else {
                Text("Worktrees will appear here.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 50)
    }

    private func groupHeader(_ title: String, canSelect: Bool) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            if canSelect {
                // Two states, not a flip on the first tick: it offers "select all the
                // removable ones" until they *are* all selected.
                Button(model.allEligibleSelected ? "Clear selection" : "Select eligible") {
                    if model.allEligibleSelected { model.selectedPaths.removeAll() } else { model.selectEligible() }
                }
                .buttonStyle(.borderless).font(.system(size: 11))
                .disabled(model.isBusy || model.eligibleEntries.isEmpty)
            }
        }
        .padding(.horizontal, 20).frame(height: 32)
    }

    private func cleanupRow(_ entry: CleanupEntry) -> some View {
        let blocker = model.blocker(for: entry)
        // A blocked row keeps a real (disabled) checkbox: an empty gap reads as a
        // missing control, and VoiceOver skipped it entirely.
        return HStack(spacing: 5) {
            Toggle(isOn: Binding(
                get: { model.selectedPaths.contains(entry.id) },
                set: { selected in
                    guard blocker == nil else { return }
                    if selected { model.selectedPaths.insert(entry.id) } else { model.selectedPaths.remove(entry.id) }
                }
            )) { rowLabel(entry, blocker: blocker) }
            .toggleStyle(.checkbox)
            .disabled(model.isBusy || blocker != nil)
            .accessibilityLabel("Select \(entry.worktree.branch ?? entry.worktree.name)")
            .accessibilityValue(blocker?.shortLabel ?? "")
        }
        .padding(.horizontal, 20).frame(minHeight: 36)
        .background(Palette.accent.opacity(model.selectedPaths.contains(entry.id) ? 0.08 : 0))
        .rowHighlight(isSelected: false)
    }

    private func rowLabel(_ entry: CleanupEntry, blocker: CleanupBlocker?) -> some View {
        HStack(spacing: 12) {
            Text(entry.worktree.branch ?? entry.worktree.name)
                .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(entry.worktree.path)
            Spacer(minLength: 0)
            if model.removedPaths.contains(entry.id) {
                Label("Removed", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // The group header above already says these rows are not merged.
            if let blocker, blocker != .notMerged {
                Text(blocker.shortLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).help(blocker.detail)
            }
        }
        .frame(maxWidth: .infinity)
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
        HStack(spacing: 8) {
            // The progress lives here while the rows stay readable above it.
            if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.isRemoving ? "Removing…" : "Checking worktrees…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isRemoving)
            Button(model.selectedEntries.isEmpty ? "Remove…" : "Remove \(model.selectedEntries.count)…", role: .destructive) {
                model.requestRemoval()
            }
            .disabled(model.isBusy || model.selectedEntries.isEmpty)
            .monospacedDigit()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// The branches are listed in the sheet behind the dialog, so the message says what
    /// will happen rather than repeating five of their names.
    private func confirmationText(_ plan: WorktreeCleanupModel.RemovalPlan) -> String {
        var text = "The selected folders will be deleted from your Mac. Branches will be kept."
        if plan.includingIgnored { text += " Ignored files inside those folders will also be deleted." }
        return text
    }
}
