import SwiftUI
import TeebeCore

/// The "What's New" window: the app logo + version, then the changelog rendered as
/// grouped, bulleted release notes. Shown automatically the first launch after an
/// update, and on demand from Help → What's New.
struct WhatsNewView: View {
    @Bindable var model: WhatsNewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.hasContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(model.entries) { entry in
                            entryView(entry)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No release notes available.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 440, height: 520)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = Brand.logo {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("What's New in \(Brand.name)")
                    .font(.system(size: 16, weight: .semibold))
                Text(model.displayVersion)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func entryView(_ entry: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.isUnreleased ? "Unreleased" : "Version \(entry.version)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.accent)
                if let date = entry.date {
                    Text(date).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            // Flat bullet list per version — the Added/Changed/Fixed groupings live
            // in CHANGELOG.md for authoring, but users just see what changed.
            VStack(alignment: .leading, spacing: 5) {
                ForEach(entry.groups.flatMap(\.items), id: \.self) { item in
                    bullet(item)
                }
            }
        }
    }

    private func bullet(_ item: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("•").foregroundStyle(Palette.secondaryText)
            ChipFlow(spacing: 3, lineSpacing: 6) {
                ForEach(Array(tokens(for: item).enumerated()), id: \.offset) { _, token in
                    switch token {
                    case let .word(text, bold):
                        Text(text)
                            .font(.system(size: 12.5, weight: bold ? .semibold : .regular))
                            .foregroundStyle(.primary)
                    case let .chip(text):
                        Text(text)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Split a bullet's inline markdown into flow tokens: plain words (optionally bold)
    /// and `code` spans. Working word-by-word (instead of one `Text`) lets the code
    /// spans render as real rounded chip views that wrap inline with the prose.
    private func tokens(for item: String) -> [BulletToken] {
        guard let parsed = try? AttributedString(markdown: item) else {
            return item.split(separator: " ").map { .word(String($0), bold: false) }
        }
        var out: [BulletToken] = []
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            if run.inlinePresentationIntent?.contains(.code) == true {
                out.append(.chip(text.trimmingCharacters(in: .whitespaces)))
            } else {
                let bold = run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                    out.append(.word(String(word), bold: bold))
                }
            }
        }
        return out
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}

/// A flow token: a plain (optionally bold) word, or a `code` span shown as a chip.
private enum BulletToken {
    case word(String, bold: Bool)
    case chip(String)
}

/// A left-to-right wrapping layout that aligns every item on the text baseline, so the
/// rounded chip views sit inline with the prose and wrap to new lines cleanly (no
/// trailing slivers, unlike an inline-text background).
private struct ChipFlow: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 6

    private struct Metric { let size: CGSize; let baseline: CGFloat }

    private func metric(_ subview: LayoutSubview) -> Metric {
        let dim = subview.dimensions(in: .unspecified)
        return Metric(size: CGSize(width: dim.width, height: dim.height),
                      baseline: dim[VerticalAlignment.firstTextBaseline] ?? dim.height)
    }

    /// Group subview indices into rows that each fit within `maxWidth`.
    private func rows(_ subviews: Subviews, maxWidth: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var row: [Int] = []
        var x: CGFloat = 0
        for index in subviews.indices {
            let width = metric(subviews[index]).size.width
            if !row.isEmpty, x + width > maxWidth {
                rows.append(row); row = []; x = 0
            }
            row.append(index)
            x += width + spacing
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(subviews, maxWidth: maxWidth)
        var height: CGFloat = 0
        var width: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let metrics = row.map { metric(subviews[$0]) }
            let ascent = metrics.map(\.baseline).max() ?? 0
            let descent = metrics.map { $0.size.height - $0.baseline }.max() ?? 0
            height += ascent + descent + (i < rows.count - 1 ? lineSpacing : 0)
            let rowWidth = metrics.reduce(0) { $0 + $1.size.width + spacing } - spacing
            width = max(width, rowWidth)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(width, 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            let metrics = row.map { metric(subviews[$0]) }
            let ascent = metrics.map(\.baseline).max() ?? 0
            let descent = metrics.map { $0.size.height - $0.baseline }.max() ?? 0
            var x = bounds.minX
            for (offset, index) in row.enumerated() {
                let m = metrics[offset]
                subviews[index].place(at: CGPoint(x: x, y: y + ascent - m.baseline),
                                      proposal: ProposedViewSize(m.size))
                x += m.size.width + spacing
            }
            y += ascent + descent + lineSpacing
        }
    }

    /// Report the first row's baseline so an enclosing `firstTextBaseline` HStack (the
    /// bullet dot) lines up with the first line of text.
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect,
                           proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline,
              let first = rows(subviews, maxWidth: bounds.width).first else { return nil }
        return first.map { metric(subviews[$0]).baseline }.max()
    }
}
