import SwiftUI
import TreebranchCore

/// The floating Quick Look panel (PRD §5.2): diff for a changed file, read-only
/// text for an unchanged text file, otherwise a hand-off to the native app.
struct PreviewPanel: View {
    @Bindable var preview: PreviewModel
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Unified vs. side-by-side diff, persisted across sessions.
    @AppStorage("diff.splitView") private var splitView = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(WindowAccessor { $0?.level = .floating }) // peek stays above the main window
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onChange(of: preview.currentPath) { focused = true }
        // Space toggles the peek shut (Quick Look convention); Esc does too.
        .onKeyPress(.space) { close(); return .handled }
        .onExitCommand { close() }
    }

    private func close() {
        preview.close()
        dismiss()
    }

    private var diffFile: DiffFile? {
        if case .diff(let file) = preview.content { return file }
        return nil
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(preview.currentPath.map { ($0 as NSString).lastPathComponent } ?? "Preview")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if let diffFile {
                Text("+\(diffFile.addedCount)")
                    .foregroundStyle(.green)
                Text("−\(diffFile.removedCount)")
                    .foregroundStyle(.red)
            }
            Spacer()
            if diffFile != nil {
                Picker("", selection: $splitView) {
                    Image(systemName: "text.alignleft").tag(false)
                    Image(systemName: "rectangle.split.2x1").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Unified or side-by-side")
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch preview.content {
        case .empty:
            ContentUnavailableView("Select a file and press space", systemImage: "eye")
        case .diff(let file):
            DiffContentView(file: file, splitView: splitView)
        case .text(let text):
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        case .quickLook(let url):
            VStack(spacing: 8) {
                Image(systemName: "doc")
                    .font(.largeTitle)
                Text("No in-app preview for \(url.lastPathComponent)")
                    .foregroundStyle(.secondary)
                Button("Open in default app") {
                    app.open(FileNode(path: url.path, isDirectory: false))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Renders a unified diff (wrapping to fill the window) or a VSCode-style
/// side-by-side split (DESIGN_BRIEF §2).
struct DiffContentView: View {
    let file: DiffFile
    var splitView: Bool = false

    var body: some View {
        if file.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc.zipper")
        } else if file.hunks.isEmpty {
            ContentUnavailableView("No textual changes", systemImage: "doc")
        } else if splitView {
            SplitDiffView(file: file)
        } else {
            UnifiedDiffView(file: file)
        }
    }
}

// MARK: - Unified

/// Single-column unified diff. Long lines wrap (with a hanging indent past the
/// gutter) so the text fills the window instead of scrolling sideways.
private struct UnifiedDiffView: View {
    let file: DiffFile

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    HunkHeader(hunk: hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        UnifiedLineRow(line: line)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
    }
}

private struct UnifiedLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(line.oldLineNumber)
            LineNumber(line.newLineNumber)
            Text(DiffStyle.marker(line.kind))
                .foregroundStyle(DiffStyle.foreground(line.kind).opacity(0.7))
                .frame(width: 14, alignment: .center)
            Text(line.content.isEmpty ? " " : line.content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(DiffStyle.foreground(line.kind))
        .padding(.vertical, 1)
        .padding(.trailing, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffStyle.background(line.kind))
    }
}

// MARK: - Split (side-by-side)

/// Two-column diff: old revision on the left, new on the right, deletions and
/// additions paired row-for-row (VSCode-style). Each column wraps within its half.
private struct SplitDiffView: View {
    let file: DiffFile

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                    HunkHeader(hunk: hunk)
                    ForEach(Array(SplitRow.rows(for: hunk).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 0) {
                            SplitCell(line: row.left, number: row.left?.oldLineNumber)
                            Divider()
                            SplitCell(line: row.right, number: row.right?.newLineNumber)
                        }
                    }
                }
            }
            .textSelection(.enabled)
        }
    }
}

private struct SplitCell: View {
    let line: DiffLine?
    let number: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number)
            Text(content)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(line.map { DiffStyle.foreground($0.kind) } ?? .primary)
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private var content: String {
        guard let line, !line.content.isEmpty else { return " " }
        return line.content
    }

    // No counterpart on this side → a faint filler band, like VSCode's gaps.
    private var background: Color {
        guard let line else { return Color.secondary.opacity(0.06) }
        return DiffStyle.background(line.kind)
    }
}

/// A paired row for the split view: the left (old) and right (new) line, either of
/// which may be absent.
private struct SplitRow {
    var left: DiffLine?
    var right: DiffLine?

    /// Pair a hunk's lines: context lines sit on both sides; a run of deletions and
    /// additions is zipped row-for-row, with leftovers landing on one side only.
    static func rows(for hunk: DiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [DiffLine] = []
        var adds: [DiffLine] = []

        func flush() {
            for index in 0..<max(dels.count, adds.count) {
                rows.append(SplitRow(
                    left: index < dels.count ? dels[index] : nil,
                    right: index < adds.count ? adds[index] : nil
                ))
            }
            dels.removeAll(keepingCapacity: true)
            adds.removeAll(keepingCapacity: true)
        }

        for line in hunk.lines {
            switch line.kind {
            case .context:
                flush()
                rows.append(SplitRow(left: line, right: line))
            case .deletion:
                dels.append(line)
            case .addition:
                adds.append(line)
            }
        }
        flush()
        return rows
    }
}

// MARK: - Shared pieces

private struct HunkHeader: View {
    let hunk: DiffHunk

    var body: some View {
        let suffix = hunk.header.isEmpty ? "" : " " + hunk.header
        Text("@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@\(suffix)")
            .font(.system(size: 11.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10))
    }
}

private struct LineNumber: View {
    let value: Int?
    init(_ value: Int?) { self.value = value }

    var body: some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .trailing)
            .padding(.trailing, 6)
    }
}

private enum DiffStyle {
    static func marker(_ kind: DiffLineKind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }
    static func foreground(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .primary
        }
    }
    static func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.12)
        case .deletion: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}
