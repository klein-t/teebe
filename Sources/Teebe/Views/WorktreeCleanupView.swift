import SwiftUI
import TeebeCore

struct WorktreeCleanupView: View {
    @State private var model: WorktreeCleanupModel
    @Environment(\.dismiss) private var dismiss

    init(app: AppModel, repo: Repository) {
        _model = State(initialValue: WorktreeCleanupModel(app: app, repo: repo))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            targetControls
            Divider()
            listControls
            worktreeList
            if model.entries.contains(where: \.hasIgnoredFiles) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Also remove ignored files", isOn: $model.includeIgnored)
                        .toggleStyle(.checkbox)
                        .disabled(model.isBusy)
                    Text("Includes ignored build output and local settings inside selected folders.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = model.resultMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let error = model.errorMessage {
                ScrollView {
                    Text(error).font(.callout).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }.frame(maxHeight: 65)
            }
            Divider()
            footer
        }
        .padding(20)
        .frame(width: 620, height: 560)
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
            if let plan = model.pendingRemoval {
                Text(confirmationText(plan))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Clean up worktrees").font(.title2.weight(.semibold))
            Text(model.repo.name).font(.callout).foregroundStyle(.secondary).help(model.repo.path)
            Text("Select merged worktrees to remove. Their branches will be kept.")
                .font(.callout)
        }
    }

    private var targetControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("Compare against", selection: Binding(
                get: { model.targetOverride },
                set: { ref in Task { await model.chooseTarget(ref) } }
            )) {
                Text(model.automaticLabel).tag("")
                ForEach(model.targets.branches) { branch in
                    Text(branch.name).tag(branch.ref)
                }
                if !model.targetOverride.isEmpty, !model.targets.branches.contains(where: { $0.ref == model.targetOverride }) {
                    Text("Saved branch unavailable").tag(model.targetOverride)
                }
            }
            .disabled(model.isBusy)
            HStack {
                if let snapshot = model.snapshot {
                    Text("Local history · checked \(snapshot.checkedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Checks use local Git history.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Recheck") { Task { await model.refresh() } }.disabled(model.isBusy)
                Button("Fetch & recheck") { Task { await model.refresh(fetch: true) } }
                    .disabled(model.isBusy)
                    .help("Connect to this repository's remotes to fetch their latest commits, then check again.")
            }
            if model.snapshot != nil, model.snapshot?.target == nil {
                Text("Choose a comparison branch above. No branch will be assumed.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var listControls: some View {
        HStack {
            Toggle("Merged only", isOn: $model.mergedOnly).toggleStyle(.checkbox)
            Spacer()
            Button("Select eligible") { model.selectEligible() }
                .disabled(model.isBusy || model.eligibleEntries.isEmpty)
            Button("Clear") { model.selectedPaths.removeAll() }
                .disabled(model.isBusy || model.selectedPaths.isEmpty)
        }
        .font(.callout)
    }

    private var worktreeList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.visibleEntries) { entry in cleanupRow(entry) }
                if model.isBusy {
                    ProgressView(model.isRemoving ? "Rechecking and removing…" : "Checking worktrees…")
                        .controlSize(.small).padding(30)
                } else if model.visibleEntries.isEmpty {
                    Text(model.mergedOnly ? "No confirmed merged worktrees." : "No worktrees to show.")
                        .foregroundStyle(.secondary).padding(30)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private func cleanupRow(_ entry: CleanupEntry) -> some View {
        let blocker = model.blocker(for: entry)
        return HStack(spacing: 10) {
            Toggle("Select \(entry.worktree.branch ?? entry.worktree.name)", isOn: Binding(
                get: { model.selectedPaths.contains(entry.id) },
                set: { selected in
                    if selected { model.selectedPaths.insert(entry.id) } else { model.selectedPaths.remove(entry.id) }
                }
            ))
            .labelsHidden().toggleStyle(.checkbox)
            .disabled(model.isBusy || blocker != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.worktree.branch ?? entry.worktree.name)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .help(entry.worktree.path)
                Text(mergeLabel(entry))
                    .font(.caption).foregroundStyle(entry.mergeStatus == .merged ? Palette.green : .secondary)
                    .help("A squash merge may contain the changes without the original commits, so it cannot be confirmed by this history check.")
            }
            Spacer(minLength: 8)
            Text(blocker ?? (entry.hasIgnoredFiles ? "Ignored files included" : "Ready to remove"))
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing).frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .rowHighlight(isSelected: false)
    }

    private func mergeLabel(_ entry: CleanupEntry) -> String {
        switch entry.mergeStatus {
        case .merged: return "Merged into \(model.snapshot?.target?.name ?? "target")"
        case .notConfirmed: return "Merge not confirmed"
        case .unknown: return "Unknown"
        }
    }

    private var footer: some View {
        HStack {
            Text("\(model.selectedEntries.count) selected").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isRemoving)
            Button("Remove selected…", role: .destructive) { model.requestRemoval() }
                .disabled(model.isBusy || model.selectedEntries.isEmpty)
        }
    }

    private func confirmationText(_ plan: WorktreeCleanupModel.RemovalPlan) -> String {
        var text = "The selected folders will be deleted from your Mac. Branches will be kept. Each worktree will be checked again before removal."
        if plan.includingIgnored { text += " Ignored files inside those folders will also be deleted." }
        text += "\n\n" + plan.entries.prefix(5).map { $0.worktree.branch ?? $0.worktree.name }.joined(separator: "\n")
        if plan.entries.count > 5 { text += "\nAnd \(plan.entries.count - 5) more." }
        return text
    }
}
