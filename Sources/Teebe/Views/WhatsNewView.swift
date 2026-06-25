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
            Text(attributed(item))
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// Render inline markdown (bold, code, links) for a bullet, falling back to plain
    /// text if it can't be parsed.
    private func attributed(_ item: String) -> AttributedString {
        (try? AttributedString(markdown: item)) ?? AttributedString(item)
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
