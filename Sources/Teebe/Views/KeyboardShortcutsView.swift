import SwiftUI

/// The Keyboard Shortcuts cheat sheet: every shortcut grouped by what it acts on.
/// Opened with `?` (or Help → Keyboard Shortcuts, ⌘/) and dismissed with Esc/Close.
/// Its content comes from `ShortcutsCatalog`, the single source of truth.
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(ShortcutsCatalog.groups) { group in
                        groupView(group)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 560)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let logo = Brand.logo {
                Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                    .frame(width: 44, height: 44)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Keyboard Shortcuts")
                    .font(.system(size: 16, weight: .semibold))
                Text("Drive \(Brand.name) without the mouse")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(group.title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.accent)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: ShortcutItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            keyChips(item.keys)
                .frame(width: 150, alignment: .leading)
            Text(item.action)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Render a row's `keys` string as rounded keycap chips: split alternatives on
    /// " / " (joined by a dim slash), and for gestures like "⌘-click" chip the modifier
    /// and keep "-click" as plain text. Matches the chip style in the What's New window.
    private func keyChips(_ keys: String) -> some View {
        let segments = keys.components(separatedBy: " / ")
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                if index > 0 {
                    Text("/").font(.system(size: 11)).foregroundStyle(Palette.secondaryText)
                }
                if let dash = segment.range(of: "-click") {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        chip(String(segment[segment.startIndex..<dash.lowerBound]))
                        Text("-click").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                } else {
                    chip(segment)
                }
            }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.primary)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )
    }

    private var footer: some View {
        HStack {
            Text("Open anytime with ?")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
