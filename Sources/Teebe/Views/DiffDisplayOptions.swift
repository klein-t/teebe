import AppKit
import SwiftUI
import TeebeCore

/// The diff preview's three reading options, stored in user defaults so the
/// panel header and Settings share them and they survive relaunches.
enum DiffDisplayOptions {
    static let syntaxColorsKey = "diff.syntaxColors"
    static let changedWordsKey = "diff.changedWords"
    static let ignoreWhitespaceKey = "diff.ignoreWhitespace"

    static let syntaxColorsTitle = "Syntax Colors"
    static let changedWordsTitle = "Changed Words"
    static let ignoreWhitespaceTitle = "Ignore Whitespace"

    static let syntaxColorsHelp = "Color code by language"
    static let changedWordsHelp = "Mark the words that changed inside edited lines"
    static let ignoreWhitespaceHelp = "Hide changes that only touch whitespace (W)"
}

/// Compact icon toggles for the preview header, beside the unified and
/// side-by-side choice.
struct DiffOptionToggles: View {
    @AppStorage(DiffDisplayOptions.syntaxColorsKey) private var syntaxColors = true
    @AppStorage(DiffDisplayOptions.changedWordsKey) private var changedWords = true
    @AppStorage(DiffDisplayOptions.ignoreWhitespaceKey) private var ignoreWhitespace = false

    var body: some View {
        HStack(spacing: 2) {
            toggle(DiffDisplayOptions.syntaxColorsTitle, "paintpalette", DiffDisplayOptions.syntaxColorsHelp, $syntaxColors)
            toggle(DiffDisplayOptions.changedWordsTitle, "highlighter", DiffDisplayOptions.changedWordsHelp, $changedWords)
            toggle(DiffDisplayOptions.ignoreWhitespaceTitle, "space", DiffDisplayOptions.ignoreWhitespaceHelp, $ignoreWhitespace)
        }
        .fixedSize()
    }

    private func toggle(_ title: String, _ symbol: String, _ help: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            // One fixed box for every symbol: their own heights differ (the
            // space glyph is flat), which made the buttons different sizes.
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 16, height: 14)
        }
        .toggleStyle(.button)
        .accessibilityLabel(title)
        .hoverHelp(help, highlight: false)
    }
}

/// The same three options in Settings.
struct DiffSettingsSection: View {
    @AppStorage(DiffDisplayOptions.syntaxColorsKey) private var syntaxColors = true
    @AppStorage(DiffDisplayOptions.changedWordsKey) private var changedWords = true
    @AppStorage(DiffDisplayOptions.ignoreWhitespaceKey) private var ignoreWhitespace = false

    var body: some View {
        Section {
            Toggle(DiffDisplayOptions.syntaxColorsTitle, isOn: $syntaxColors)
                .hoverHelp(DiffDisplayOptions.syntaxColorsHelp, highlight: false)
            Toggle(DiffDisplayOptions.changedWordsTitle, isOn: $changedWords)
                .hoverHelp(DiffDisplayOptions.changedWordsHelp, highlight: false)
            Toggle(DiffDisplayOptions.ignoreWhitespaceTitle, isOn: $ignoreWhitespace)
                .hoverHelp(DiffDisplayOptions.ignoreWhitespaceHelp, highlight: false)
        } header: { Text("Diff preview") } footer: {
            Text("Also in the preview header. Press W in the preview to ignore whitespace.")
        }
    }
}

// MARK: - Styling

/// Styled text per hunk and line of one diff; nil lines stay plain.
struct DiffHighlight: Sendable {
    let lines: [[AttributedString?]]

    func line(_ hunk: Int, _ line: Int) -> AttributedString? {
        guard lines.indices.contains(hunk), lines[hunk].indices.contains(line) else { return nil }
        return lines[hunk][line]
    }
}

enum DiffHighlighter {
    /// Not on the main actor: tokenizing and pairing run on the cooperative pool
    /// and stop early when the caller's task is cancelled.
    static func make(file: DiffFile, syntaxColors: Bool, changedWords: Bool,
                     ignoringWhitespace: Bool = false) async -> DiffHighlight? {
        let language = syntaxColors ? SyntaxLanguage.forPath(file.displayPath) : nil
        guard language != nil || changedWords,
              let runs = DiffHighlighting.runs(for: file, language: language, changedWords: changedWords,
                                               ignoringWhitespace: ignoringWhitespace,
                                               isCancelled: { Task.isCancelled }) else { return nil }
        var lines: [[AttributedString?]] = []
        for (hunk, hunkRuns) in zip(file.hunks, runs) {
            if Task.isCancelled { return nil }
            lines.append(zip(hunk.lines, hunkRuns).map { line, lineRuns in
                lineRuns.map { attributed(line, runs: $0) }
            })
        }
        return DiffHighlight(lines: lines)
    }

    static func attributed(_ line: DiffLine, runs: [DiffLineRun]) -> AttributedString {
        let chars = Array(line.content)
        var result = AttributedString()
        for run in runs where run.range.upperBound <= chars.count {
            var piece = AttributedString(String(chars[run.range]))
            if let kind = run.kind {
                piece.foregroundColor = DiffPalette.color(kind)
                if kind == .comment { piece.font = .system(size: 12, design: .monospaced).italic() }
            }
            if run.changed { piece.backgroundColor = DiffPalette.changedBackground(line.kind) }
            result.append(piece)
        }
        return result
    }
}

/// Token colors chosen to stay readable on the added and removed tints in both
/// appearances (GitHub-like hues, darker in light mode, lighter in dark mode).
enum DiffPalette {
    static func color(_ kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .comment: return dynamic(light: 0x57606A, dark: 0x8B949E)
        case .string: return dynamic(light: 0x0A3069, dark: 0xA5D6FF)
        case .number: return dynamic(light: 0x0550AE, dark: 0x79C0FF)
        case .keyword: return dynamic(light: 0x8250DF, dark: 0xD2A8FF)
        case .type: return dynamic(light: 0x953800, dark: 0xFFA657)
        }
    }

    /// Changed words: the line's own hue, several times stronger, so they stand
    /// out by lightness as well as by hue.
    static func changedBackground(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .addition: return Color(nsColor: tint(.systemGreen, light: 0.34, dark: 0.42))
        case .deletion: return Color(nsColor: tint(.systemRed, light: 0.30, dark: 0.42))
        case .context: return .clear
        }
    }

    private static func tint(_ base: NSColor, light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return base.withAlphaComponent(isDark ? dark : light)
        }
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
