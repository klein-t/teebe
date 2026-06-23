import SwiftUI
import AppKit
import TeebeCore

/// App branding: the official name and logo (bundled as a package resource).
enum Brand {
    static let name = "teebe"

    /// The teebe logo, loaded once from the app bundle. Used for the empty state
    /// and the Dock / app icon.
    static let logo: NSImage? = resourceBundle?
        .url(forResource: "teebe-logo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    /// Locate the SwiftPM resource bundle (`Teebe_Teebe.bundle`) across run modes.
    /// We deliberately avoid `Bundle.module`: its generated accessor only checks
    /// the app *root* (`Bundle.main.bundleURL/Teebe_Teebe.bundle`) plus a hardcoded
    /// build path, and **fatal-errors** when neither exists. A code-signed `.app`
    /// can't keep resources at its root (codesign requires everything under
    /// `Contents/`), so in a packaged build the bundle lives in `Contents/Resources/`.
    /// Probe both that and the dir next to the executable (`swift run`).
    private static let resourceBundle: Bundle? = {
        let bundleName = "Teebe_Teebe.bundle"
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            if let bundle = Bundle(url: candidate) { return bundle }
        }
        // Fall back to the main bundle itself (resources copied in flat).
        return Bundle.main
    }()
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
///
/// The pulse is driven off `active` via `onChange`, not a one-shot `onAppear`, so
/// a worktree that goes live *after* the row appears starts pulsing, and one that
/// goes idle stops — the previous version latched whatever state it saw at appear.
struct LiveDot: View {
    var active: Bool
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(active ? Palette.live : Color(white: 0.79))
            .frame(width: 7, height: 7)
            .overlay(ring)
            .animation(.easeInOut(duration: 0.25), value: active)   // fade the fill on state change
            .onAppear { syncPulse() }
            .onChange(of: active) { _, _ in syncPulse() }
    }

    /// The expanding halo. Hidden entirely while idle so a stopped pulse can't
    /// leave a faint ring frozen mid-cycle.
    private var ring: some View {
        Circle()
            .stroke(Palette.live, lineWidth: 2)
            .scaleEffect(animate ? 2.4 : 1)
            .opacity(animate ? 0 : 0.5)
            .opacity(active ? 1 : 0)
    }

    private func syncPulse() {
        if active {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { animate = true }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { animate = false }
        }
    }
}

// MARK: - Press / hover chrome for compact controls

/// Tactile press feedback for prominent action buttons (e.g. Commit): the whole
/// labelled surface scales to `0.96` while pressed and eases back when released.
/// The skill's floor is `0.95` — anything smaller reads as exaggerated. Keep the
/// button's background *inside* its label so the scale covers the entire control,
/// not just the text.
struct PressableButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// Shared hover-chip + press chrome for compact glyph controls. A bare 11–13pt
/// SF Symbol gives an ~11×11 hit target; this wraps it in a comfortable hit area
/// with a subtle hover background and (for buttons) a `0.96` press scale.
private struct ChipBody<Label: View>: View {
    let size: CGSize
    var pressed = false
    @ViewBuilder var label: () -> Label
    @State private var hovering = false

    var body: some View {
        label()
            .frame(minWidth: size.width, minHeight: size.height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.08 : 0))
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.12), value: pressed)
            .onHover { hovering = $0 }
    }
}

/// Compact glyph **button** style: comfortable hit area, hover chip, press scale.
/// Replaces bare `.buttonStyle(.plain)` on toolbar-style icon buttons. Default
/// size is sized to stay within a 32pt header without colliding with neighbours.
struct IconButtonStyle: ButtonStyle {
    var size = CGSize(width: 22, height: 28)
    func makeBody(configuration: Configuration) -> some View {
        ChipBody(size: size, pressed: configuration.isPressed) { configuration.label }
    }
}

/// The same hit area + hover chip for controls that can't take a `ButtonStyle`
/// (notably `Menu`). No press scale — menus open on press, so a scale would fight
/// the popover.
private struct HoverChipModifier: ViewModifier {
    var size: CGSize
    func body(content: Content) -> some View {
        ChipBody(size: size) { content }
    }
}

extension View {
    /// Wrap a compact control (e.g. a `Menu` label) in a hit area + hover chip
    /// matching `IconButtonStyle`.
    func hoverChip(_ size: CGSize = CGSize(width: 22, height: 28)) -> some View {
        modifier(HoverChipModifier(size: size))
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
            // The native macOS DisclosureGroup glyph: a `chevron.right` is a thin,
            // doubly-symmetric stroke whose ink centroid coincides with its
            // bounding-box center, so rotating it about the default `.center` anchor
            // is a true spin-in-place. A *filled* `arrowtriangle.right.fill` has its
            // area-centroid 1/3 from the base, NOT at the bbox center, so rotating it
            // swept the visual mass through an arc — a left/down lurch read as a
            // "bounce" that survives any easing curve and any glyph SOURCE swap
            // (text→symbol) because it is geometric, not temporal. A square frame +
            // explicit `.center` anchor pins the pivot to the glyph's visual center.
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.secondaryText)
                .frame(width: 13, height: 13)
                .rotationEffect(.degrees(isOpen ? 90 : 0), anchor: .center)
                // No animation — snap in lockstep with the window. A section toggle
                // resizes the window, which SNAPS (setFrame display:true) on close
                // and on the worktree-only grow; a chevron animating its rotation
                // against that synchronous snap hitches, and THAT was the residual
                // "bounce". Snapping the arrow removes it. (Opening CHANGES/FILES
                // glides the window open; an already-flipped arrow rides along fine.)
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
        // The layout/window resize is animated by RootView.setOpen (it eases on
        // open but snaps on close, so the window and content never desync and
        // bounce). The header just reports the toggle.
        .onTapGesture { onToggle() }
    }
}

extension SelectorModel.WorktreeInfo {
    /// "↓behind ↑ahead" sync indicator.
    var syncText: String { "↓\(behind) ↑\(ahead)" }
}
