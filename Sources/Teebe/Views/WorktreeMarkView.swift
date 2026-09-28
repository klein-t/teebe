import AppKit
import SwiftUI
import TeebeCore

/// The one status mark a worktree row shows, also used by the hover card and the
/// group headers. On a selected (accent) row every mark reads white.
struct WorktreeMarkView: View {
    let mark: WorktreeMark
    var isSelected = false
    /// Stops the orbs while the window is occluded (`SelectorModel.isLowPower`).
    var paused = false
    /// What the orb's phase derives from, typically the worktree path, so orbs of
    /// different worktrees move out of step and each keeps its own.
    var phaseKey = ""
    @Environment(\.colorScheme) private var colorScheme

    static let uncommittedColor = Color(red: 0xF0 / 255, green: 0x8C / 255, blue: 0x1A / 255)

    private var isDark: Bool { colorScheme == .dark }
    private var phase: Double { ThinkingOrbStyle.phaseOffset(for: phaseKey) }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(mark))
            .accessibilityHidden(mark == .none)
    }

    @ViewBuilder
    private var content: some View {
        switch mark {
        case .working:
            ThinkingOrbView(state: .solving,
                            ink: isDark || isSelected ? .white : Color(red: 0x14 / 255, green: 0x63 / 255, blue: 0xD6 / 255),
                            isDark: isDark || isSelected, scale: 0.85, paused: paused, phase: phase)
        case .waiting:
            ThinkingOrbView(state: .breathing, ink: waitingInk, isDark: isDark || isSelected, scale: 0.85,
                            paused: paused, phase: phase)
        case .uncommitted:
            Circle().fill(isSelected ? Color.white : Self.uncommittedColor).frame(width: 8, height: 8)
        case .brokenLink:
            BrokenLinkShape()
                .stroke(isSelected ? Color.white : Color(nsColor: .tertiaryLabelColor),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .frame(width: 14, height: 14)
        case .merged:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: .systemGreen))
        case .notMerged:
            Circle().strokeBorder(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor), lineWidth: 1.5)
                .frame(width: 9, height: 9)
        case .none:
            // Still takes the slot, so a mark-less row's name lines up with the rest.
            Color.clear
        }
    }

    private var waitingInk: Color {
        if isSelected { return .white }
        return isDark ? Color(red: 0xFF / 255, green: 0xC0 / 255, blue: 0x70 / 255)
            : Color(red: 0xC8 / 255, green: 0x64 / 255, blue: 0x00 / 255)
    }

    static func accessibilityLabel(_ mark: WorktreeMark) -> String {
        switch mark {
        case .working: "Agent working"
        case .waiting: "Agent waiting for you"
        case .uncommitted: "Uncommitted changes"
        case .brokenLink: "Worktree link broken"
        case .merged: "Merged"
        case .notMerged: "Not merged"
        case .none: ""
        }
    }
}

/// A chain link with a slash through it: the folder's `.git` link is gone. Drawn
/// on a 24-unit grid (SF Symbols has no broken-link glyph).
struct BrokenLinkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 9, y: 17))
        path.addLine(to: CGPoint(x: 7, y: 17))
        path.addArc(center: CGPoint(x: 7, y: 12), radius: 5, startAngle: .degrees(90), endAngle: .degrees(270),
                    clockwise: false)
        path.addLine(to: CGPoint(x: 9, y: 7))
        path.move(to: CGPoint(x: 15, y: 7))
        path.addLine(to: CGPoint(x: 17, y: 7))
        path.addArc(center: CGPoint(x: 17, y: 12), radius: 5, startAngle: .degrees(-90), endAngle: .degrees(36.87),
                    clockwise: false)
        path.move(to: CGPoint(x: 8, y: 12))
        path.addLine(to: CGPoint(x: 11, y: 12))
        path.move(to: CGPoint(x: 3, y: 3))
        path.addLine(to: CGPoint(x: 21, y: 21))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24)
            .translatedBy(x: rect.minX, y: rect.minY))
    }
}

/// The git-merge glyph: a line running down from one commit, with a second
/// commit curving in to join it. Drawn on a 24-unit grid; stroke it.
struct MergeGlyphShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius: CGFloat = 2.6
        // The branch that stays: a commit at the top, its line running down.
        path.addEllipse(in: CGRect(x: 6 - radius, y: 5 - radius, width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: 6, y: 5 + radius))
        path.addLine(to: CGPoint(x: 6, y: 22))
        // The merged branch: its commit, bottom right, curving into the line.
        path.addEllipse(in: CGRect(x: 18.5 - radius, y: 17 - radius, width: radius * 2, height: radius * 2))
        path.move(to: CGPoint(x: 18.5 - radius, y: 17))
        path.addQuadCurve(to: CGPoint(x: 6, y: 8.5), control: CGPoint(x: 6, y: 17))
        return path.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: rect.width / 24, y: rect.height / 24))
    }
}

/// An icon-led line of the hover card and the removal sheets.
struct WorktreeFactRow: View {
    let fact: WorktreeCardFact
    /// Secondary in the hover card, body in the sheets.
    var font = Typography.secondary

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 13, height: 13)
                .foregroundStyle(iconColor)
            Text(fact.text)
                .font(font).monospacedDigit()
                .foregroundStyle(fact.tone == .muted ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch fact.tone {
        case .warn: WorktreeMarkView.uncommittedColor
        case .positive: Color(nsColor: .systemGreen)
        case .normal, .muted: Color.secondary
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch fact.icon {
        case .merge:
            // About the weight of an 11 pt SF Symbol in this 13 pt slot.
            MergeGlyphShape().stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        case .pencil: symbol("pencil")
        case .cloud: symbol("icloud")
        case .ignoredFiles: symbol("eye.slash")
        case .warning: symbol("exclamationmark.triangle")
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 11))
    }
}

/// The row's hover card: the mark, a title and one line of detail, then the facts
/// in a shaded footer.
struct WorktreeHoverCard: View {
    static let width: CGFloat = 248
    let card: WorktreeCard
    let mark: WorktreeMark
    var paused = false
    var phaseKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                WorktreeMarkView(mark: mark, paused: paused, phaseKey: phaseKey)
                    .frame(width: 22, height: 20)
                    .padding(.top, -1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(Typography.bodyEmphasis)
                    Text(card.subtitle).font(Typography.secondary).foregroundStyle(.secondary)
                        .lineSpacing(1.5)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 10, leading: 8, bottom: 9, trailing: 12))
            if !card.facts.isEmpty {
                Rectangle().fill(Self.line).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(card.facts.enumerated()), id: \.offset) { WorktreeFactRow(fact: $0.element) }
                }
                .padding(EdgeInsets(top: 7, leading: 12, bottom: 8, trailing: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Self.footer)
            }
        }
        .frame(width: Self.width)
        .background(Self.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Self.line, lineWidth: 0.5))
    }

    private static let surface = Color.dynamic(light: NSColor(white: 0.984, alpha: 1),
                                               dark: NSColor(srgbRed: 0x30 / 255, green: 0x30 / 255, blue: 0x33 / 255, alpha: 1))
    private static let footer = Color.dynamic(light: NSColor(white: 0.965, alpha: 1),
                                              dark: NSColor(srgbRed: 0x2D / 255, green: 0x2D / 255, blue: 0x30 / 255, alpha: 1))
    private static let line = Color.dynamic(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.08))
}

extension Color {
    /// A colour that follows the view's light or dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
