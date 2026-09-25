import AppKit
import SwiftUI

/// The one status mark a worktree row shows, also used by the hover card and the
/// group headers. On a selected (accent) row every mark reads white.
struct WorktreeMarkView: View {
    let mark: WorktreeMark
    var isSelected = false
    /// Stops the orbs while the window is occluded (`SelectorModel.isLowPower`).
    var paused = false
    @Environment(\.colorScheme) private var colorScheme

    static let uncommittedColor = Color(red: 0xF0 / 255, green: 0x8C / 255, blue: 0x1A / 255)

    private var isDark: Bool { colorScheme == .dark }

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
                            isDark: isDark || isSelected, paused: paused)
                .scaleEffect(0.85)
        case .waiting:
            ThinkingOrbView(state: .breathing, ink: waitingInk, isDark: isDark || isSelected, paused: paused)
                .scaleEffect(0.85)
        case .uncommitted:
            Circle().fill(isSelected ? Color.white : Self.uncommittedColor).frame(width: 8, height: 8)
        case .missing:
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
        case .missing: "Worktree missing"
        case .merged: "Merged"
        case .notMerged: "Not merged"
        case .none: ""
        }
    }
}

/// A chain link with a slash through it: the folder Git points at is gone. Drawn
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

/// An icon-led line of the hover card and the removal sheets.
struct WorktreeFactRow: View {
    let fact: WorktreeCardFact

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 13, height: 13)
                .foregroundStyle(fact.tone == .warn ? WorktreeMarkView.uncommittedColor : Color.secondary)
            Text(fact.text)
                .font(.system(size: 11.5)).monospacedDigit()
                .foregroundStyle(fact.tone == .normal || fact.tone == .warn ? Color.primary : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        if fact.icon == .missing {
            BrokenLinkShape().stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        } else {
            Image(systemName: Self.symbol(fact.icon)).font(.system(size: 11))
        }
    }

    static func symbol(_ icon: WorktreeCardIcon) -> String {
        switch icon {
        case .pencil: "pencil"
        case .merge: "arrow.triangle.merge"
        case .branch: "arrow.triangle.branch"
        case .cloud: "icloud"
        case .missing: "questionmark.folder"
        case .ignoredFiles: "eye.slash"
        case .warning: "exclamationmark.triangle"
        }
    }
}

/// The row's hover card: the mark, a title and one line of detail, then the facts
/// in a shaded footer.
struct WorktreeHoverCard: View {
    static let width: CGFloat = 248
    let card: WorktreeCard
    let mark: WorktreeMark
    var paused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                WorktreeMarkView(mark: mark, paused: paused)
                    .frame(width: 22, height: 20)
                    .padding(.top, -1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 12.5, weight: .semibold))
                    Text(card.subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary)
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
