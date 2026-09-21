import SwiftUI
import TeebeCore

/// Creating a linked worktree: the branch, what it starts from, and where the
/// folder goes. Replaces the old save panel, whose folder name doubled as the
/// branch name.
struct NewWorktreeSheet: View {
    @Bindable var app: AppModel
    @Bindable var form: NewWorktreeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Worktree").font(.system(size: 15, weight: .semibold))
            Form {
                branchField
                if form.isCreatingBranch, !form.startPoints.isEmpty { startFromPicker }
                locationField
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .padding(.horizontal, -18)
            .disabled(form.isCreating)
            if let message = form.errorMessage {
                Text(message)
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(16)
        .frame(width: 420)
    }

    private var branchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Branch", text: $form.branch, prompt: Text("feat/my-change"))
                .textFieldStyle(.roundedBorder)
            if let problem = form.branchProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if form.existingBranch != nil {
                Toggle("Use existing branch", isOn: $form.useExistingBranch)
                    .font(.system(size: 11))
            }
        }
    }

    private var startFromPicker: some View {
        Picker("Start from", selection: $form.startPoint) {
            ForEach(form.startPoints, id: \.self) { name in
                Text(name).tag(name)
            }
        }
        .pickerStyle(.menu)
    }

    private var locationField: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent("Location") {
                HStack(spacing: 8) {
                    // Read-only: the folder is derived from the branch, or picked.
                    Text(form.location.isEmpty ? "—" : form.location)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Button("Choose…") { app.chooseWorktreeLocation(for: form) }
                }
            }
            if let problem = form.locationProblem {
                Text(problem).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if form.isCreating {
                ProgressView().controlSize(.small)
                Text("Creating…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel") { app.newWorktree = nil }
                .keyboardShortcut(.cancelAction)
            Button("Create") { Task { await app.createWorktree(form) } }
                .keyboardShortcut(.defaultAction)
                .disabled(!form.canCreate)
        }
    }
}
