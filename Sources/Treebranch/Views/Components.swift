import SwiftUI
import AppKit
import TreebranchCore

/// App branding: the official name and logo (bundled as a package resource).
enum Brand {
    static let name = "teebe"

    /// The teebe logo, loaded once from the app bundle. Used for the empty state
    /// and the Dock / app icon.
    static let logo: NSImage? = Bundle.module
        .url(forResource: "teebe-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))
}

/// Shared color palette.
enum Palette {
    static let accent = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let live = Color(red: 0x30 / 255, green: 0xD1 / 255, blue: 0x58 / 255)
    static let amber = Color(red: 0xC9 / 255, green: 0x96 / 255, blue: 0x1A / 255)
    static let green = Color(red: 0x3F / 255, green: 0x96 / 255, blue: 0x55 / 255)
    static let red = Color(red: 0xD7 / 255, green: 0x00 / 255, blue: 0x15 / 255)
    static let headerLabel = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
    static let secondaryText = Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8B / 255)

    static func statusColor(_ status: ChangeStatus) -> Color {
        switch status {
        case .added, .untracked: return green
        case .modified, .typeChanged, .renamed, .copied: return amber
        case .deleted: return red
        case .conflicted: return .purple
        default: return secondaryText
        }
    }
}

/// A monospace colored git-status letter (M/A/D/U…), matching the reference.
struct StatusLetter: View {
    let change: FileChange
    var body: some View {
        if let letter = change.primaryStatus.badgeLetter {
            Text(letter)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(Palette.statusColor(change.primaryStatus))
        }
    }
}

/// A green dot that pulses while a worktree is being written to (live agent).
struct LiveDot: View {
    var active: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(active ? Palette.live : Color(white: 0.79))
            .frame(width: 7, height: 7)
            .overlay(
                Circle()
                    .stroke(Palette.live, lineWidth: 2)
                    .scaleEffect(animate ? 2.4 : 1)
                    .opacity(active ? (animate ? 0 : 0.5) : 0)
            )
            .onAppear { syncPulse() }
            // Restart/stop the pulse when liveness flips after first appearance —
            // `.onAppear` fires once, so a worktree that goes live later would
            // otherwise show a static (unpulsing) dot.
            .onChange(of: active) { syncPulse() }
    }

    private func syncPulse() {
        if active {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true }
        } else {
            withAnimation(.linear(duration: 0)) { animate = false }
        }
    }
}

/// A collapsible section header (WORKTREES / CHANGES / FILES).
struct SectionHeader<Trailing: View>: View {
    let title: String
    let isOpen: Bool
    let onToggle: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 5) {
            Text("▸")
                .font(.system(size: 15))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 13)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Palette.headerLabel)
                .fixedSize()
                .layoutPriority(1)
            Spacer(minLength: 6)
            trailing()
        }
        .padding(.horizontal, 9)
        .frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy(duration: 0.26)) { onToggle() } }
    }
}

extension SelectorModel.WorktreeInfo {
    /// "↓behind ↑ahead" sync indicator.
    var syncText: String { "↓\(behind) ↑\(ahead)" }
}
