import SwiftUI
import TeebeCore

/// Picking the one extra branch worktrees are also checked against. Every ref the
/// repository has is reachable here: the handful anyone actually means first, the
/// rest behind a search field. None clears the choice.
struct ComparisonBranchSheet: View {
    let branches: [CleanupBranch]
    let saved: String
    let onChoose: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var selection: String?
    @FocusState private var focus: Field?

    private enum Field { case search, list }

    private var sections: ComparisonBranchSections {
        ComparisonBranchMenu.sections(branches, search: search)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Also Check Merges Against").font(.system(size: 15, weight: .semibold))
                Text("Worktrees are already checked against the default branch and dev, develop, main and master. "
                     + "Pick one more branch, or None.")
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
            selection = saved
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
        .tag(item.id)
        .simultaneousGesture(TapGesture(count: 2).onEnded { choose(item.id) })
    }

    /// One match and a Return means that one, without a trip to the list.
    private func chooseOnlyMatch() {
        let visible = sections.suggested + sections.all
        guard visible.count == 1, let only = visible.first else { return }
        choose(only.id)
    }

    private func moveIntoList() {
        if selection == nil {
            selection = (sections.suggested + sections.all).first?.id
        }
        focus = .list
    }

    private func choose(_ ref: String?) {
        guard let ref else { return }
        onChoose(ref)
        dismiss()
    }
}
