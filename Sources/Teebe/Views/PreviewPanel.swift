import SwiftUI
import TeebeCore

/// The floating Quick Look panel (PRD §5.2): diff for a changed file, read-only
/// text for an unchanged text file, otherwise a hand-off to the native app.
struct PreviewPanel: View {
    @Bindable var preview: PreviewModel
    let app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Unified vs. side-by-side diff, persisted across sessions.
    @AppStorage("diff.splitView") private var splitView = false
    @AppStorage(DiffDisplayOptions.ignoreWhitespaceKey) private var ignoreWhitespace = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if ignoreWhitespace, diffFile != nil {
                whitespaceBanner
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 400)
        .background(WindowAccessor { $0?.level = .floating }) // peek stays above the main window
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onDisappear { preview.close() }
        .onChange(of: preview.currentPath) { focused = true }
        // Space toggles the peek shut (Quick Look convention); Esc does too.
        .onKeyPress(.space) { close(); return .handled }
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { step($0.key) }
        // W: ignore whitespace, as long as no command key is held.
        .onKeyPress(characters: CharacterSet(charactersIn: "wW"), phases: .down) { press in
            guard diffFile != nil, press.modifiers.isDisjoint(with: [.command, .control, .option]) else { return .ignored }
            ignoreWhitespace.toggle()
            return .handled
        }
        .onChange(of: ignoreWhitespace) { Task { await preview.reload() } }
        .onExitCommand { close() }
    }

    private var whitespaceBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "space")
            Text("Whitespace changes hidden")
            Spacer()
            Button("Show") { ignoreWhitespace = false }
                .buttonStyle(.link)
                .hoverHelp(DiffDisplayOptions.ignoreWhitespaceHelp, highlight: false)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.10))
    }

    /// Arrow keys while the peek is key: move the list selection (Finder-style) and
    /// show the newly selected file.
    private func step(_ key: KeyEquivalent) -> KeyPress.Result {
        let arrow: PeekArrow
        switch key {
        case .upArrow: arrow = .up
        case .downArrow: arrow = .down
        case .leftArrow: arrow = .left
        default: arrow = .right
        }
        let worktree = app.selector.worktree
        guard let node = worktree.stepPeek(arrow, in: app.activeSection) else { return .ignored }
        if !node.isDirectory, let worktreePath = worktree.worktreePath {
            Task { await preview.update(for: node, worktreePath: worktreePath) }
        }
        return .handled
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
                DiffOptionToggles()
                Picker("", selection: $splitView) {
                    Image(systemName: "text.alignleft").tag(false)
                    Image(systemName: "rectangle.split.2x1").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .hoverHelp("Choose unified or side-by-side diff", highlight: false)
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch preview.content {
        case .loading:
            ProgressView("Loading preview…")
        case .tooLarge(let url):
            VStack(spacing: 12) {
                ContentUnavailableView("Too large to preview", systemImage: "doc.text",
                    description: Text("Open this file in another app to view its full contents."))
                Button("Open in default app") {
                    app.open(FileNode(path: url.path, isDirectory: false))
                }
            }
            .padding()
        case .empty:
            ContentUnavailableView("Select a file and press space", systemImage: "eye")
        case .diff(let file):
            DiffContentView(file: file, splitView: splitView)
        case .text(let text):
            PreviewTextView(text: text)
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
    @AppStorage(DiffDisplayOptions.ignoreWhitespaceKey) private var ignoreWhitespace = false
    @AppStorage(DiffDisplayOptions.syntaxColorsKey) private var syntaxColors = true
    @AppStorage(DiffDisplayOptions.changedWordsKey) private var changedWords = true
    @State private var highlight: (key: HighlightKey, value: DiffHighlight)?

    private struct HighlightKey: Equatable {
        let file: DiffFile
        let syntaxColors: Bool
        let changedWords: Bool
        let ignoreWhitespace: Bool
    }

    private var key: HighlightKey {
        HighlightKey(file: file, syntaxColors: syntaxColors, changedWords: changedWords,
                     ignoreWhitespace: ignoreWhitespace)
    }

    /// Styling for this exact diff and options only; until it is ready, plain text.
    private var style: DiffStyling {
        let current = highlight.flatMap { $0.key == key ? $0.value : nil }
        let colored = syntaxColors && current != nil && SyntaxLanguage.forPath(file.displayPath) != nil
        return DiffStyling(highlight: current, syntaxColors: colored)
    }

    var body: some View {
        Group {
            if file.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc.zipper")
            } else if file.onlyWhitespaceChanged {
                VStack(spacing: 12) {
                    ContentUnavailableView("Only whitespace changed", systemImage: "space",
                        description: Text("Whitespace changes are hidden. Press W to show them."))
                    Button("Show Whitespace Changes") { ignoreWhitespace = false }
                }
                .padding()
            } else if file.hunks.isEmpty {
                ContentUnavailableView("No textual changes", systemImage: "doc")
            } else if splitView {
                SplitDiffView(file: file, style: style)
            } else {
                UnifiedDiffView(file: file, style: style)
            }
        }
        // Off the main actor and cancelled when the diff or an option changes, so
        // a large diff opens plain right away and gains its colors a moment later.
        .task(id: key) {
            let key = key
            guard key.syntaxColors || key.changedWords, !key.file.hunks.isEmpty else { return }
            guard let value = await DiffHighlighter.make(file: key.file, syntaxColors: key.syntaxColors,
                                                         changedWords: key.changedWords,
                                                         ignoringWhitespace: key.ignoreWhitespace),
                  !Task.isCancelled else { return }
            highlight = (key, value)
        }
    }
}

/// What the rows need to draw styled text.
private struct DiffStyling {
    let highlight: DiffHighlight?
    /// Token colors replace the red and green text, as on GitHub.
    let syntaxColors: Bool

    func text(_ hunk: Int, _ line: Int) -> AttributedString? { highlight?.line(hunk, line) }
}

// MARK: - Unified

/// Single-column unified diff. Long lines wrap (with a hanging indent past the
/// gutter) so the text fills the window instead of scrolling sideways.
private struct UnifiedDiffView: View {
    let file: DiffFile
    let style: DiffStyling

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    HunkHeader(hunk: hunk)
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { lineIndex, line in
                        UnifiedLineRow(line: line, styled: style.text(hunkIndex, lineIndex),
                                       syntaxColors: style.syntaxColors)
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
    var styled: AttributedString?
    var syntaxColors = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(line.oldLineNumber)
            LineNumber(line.newLineNumber)
            Text(DiffStyle.marker(line.kind))
                .foregroundStyle(DiffStyle.foreground(line.kind).opacity(0.7))
                .frame(width: 14, alignment: .center)
            DiffLineText(content: line.content, styled: styled)
                .foregroundStyle(syntaxColors ? .primary : DiffStyle.foreground(line.kind))
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
    let style: DiffStyling

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(file.hunks.enumerated()), id: \.offset) { hunkIndex, hunk in
                    HunkHeader(hunk: hunk)
                    ForEach(Array(SplitRow.rows(for: hunk).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top, spacing: 0) {
                            SplitCell(line: row.left?.line, number: row.left?.line.oldLineNumber,
                                      styled: row.left.flatMap { style.text(hunkIndex, $0.index) },
                                      syntaxColors: style.syntaxColors)
                            Divider()
                            SplitCell(line: row.right?.line, number: row.right?.line.newLineNumber,
                                      styled: row.right.flatMap { style.text(hunkIndex, $0.index) },
                                      syntaxColors: style.syntaxColors)
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
    var styled: AttributedString?
    var syntaxColors = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LineNumber(number)
            DiffLineText(content: line?.content ?? "", styled: styled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(syntaxColors ? .primary : line.map { DiffStyle.foreground($0.kind) } ?? .primary)
        .padding(.vertical, 1)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
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
    /// A line with its index in the hunk, to find its styling.
    typealias Side = (line: DiffLine, index: Int)
    var left: Side?
    var right: Side?

    /// Pair a hunk's lines: context lines sit on both sides; a run of deletions and
    /// additions is zipped row-for-row, with leftovers landing on one side only.
    static func rows(for hunk: DiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var dels: [Side] = []
        var adds: [Side] = []

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

        for (index, line) in hunk.lines.enumerated() {
            switch line.kind {
            case .context:
                flush()
                rows.append(SplitRow(left: (line, index), right: (line, index)))
            case .deletion:
                dels.append((line, index))
            case .addition:
                adds.append((line, index))
            }
        }
        flush()
        return rows
    }
}

// MARK: - Shared pieces

/// A line's text: styled when its colors are ready, plain otherwise. An empty
/// line keeps one space so the row keeps its height.
private struct DiffLineText: View {
    let content: String
    let styled: AttributedString?

    var body: some View {
        if let styled, !content.isEmpty {
            Text(styled)
        } else {
            Text(content.isEmpty ? " " : content)
        }
    }
}

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
