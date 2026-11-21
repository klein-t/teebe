import AppKit
import SwiftUI
import TeebeCore

/// The menu bar status item's label: the rows' waiting and working glyphs, each
/// with its count, drawn as one template image so it follows the menu bar's
/// appearance. The neutral teebe glyph when there is nothing to count.
struct AgentMenuBarLabel: View {
    let overview: AgentOverviewModel
    let display: AgentDisplayPreferences
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let summary = overview.summary
        let title = AgentMenuBarTitle(waiting: summary.waiting.count, working: summary.working.count,
                                      showsWaiting: display.showsWaitingCount, showsWorking: display.showsWorkingCount)
        Image(nsImage: AgentMenuBarImage.render(title))
            .accessibilityLabel(title.accessibilityLabel)
            // This view lives as long as the item, so it can reopen a closed window.
            .onAppear { MainWindowOpener.open = { openWindow(id: WindowID.main) } }
    }
}

/// Draws `AgentMenuBarTitle` as a template image.
@MainActor
enum AgentMenuBarImage {
    static let height: CGFloat = 18
    static let glyphSize: CGFloat = 16
    private static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    static func render(_ title: AgentMenuBarTitle) -> NSImage {
        guard !title.isNeutral else { return neutral }
        let pieces: [(ThinkingOrbState, String)] = title.segments.map { segment in
            switch segment {
            case .waiting(let count): return (.breathing, "\(count)")
            case .working(let count): return (.solving, "\(count)")
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: digitFont, .foregroundColor: NSColor.black]
        let digitGap: CGFloat = 2, segmentGap: CGFloat = 7
        let widths = pieces.map { glyphSize + digitGap + ceil(($0.1 as NSString).size(withAttributes: attributes).width) }
        let width = widths.reduce(0, +) + segmentGap * CGFloat(max(0, pieces.count - 1))
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (index, piece) in pieces.enumerated() {
                drawOrb(piece.0, in: NSRect(x: x, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize))
                let text = piece.1 as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x + glyphSize + digitGap, y: (height - size.height) / 2), withAttributes: attributes)
                x += widths[index] + segmentGap
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The rows' orb at its still (reduced motion) frame, depth as opacity.
    private static func drawOrb(_ state: ThinkingOrbState, in rect: NSRect) {
        let style = ThinkingOrbStyle(state: state)
        let scale = rect.width / ThinkingOrbStyle.size
        for dot in style.frame(at: ThinkingOrbStyle.staticTime) {
            let radius = max(0.6, dot.radius * scale)
            let center = NSPoint(x: rect.minX + dot.x * scale, y: rect.minY + dot.y * scale)
            let depth = 1 - 0.55 * min(1, max(0, dot.white))
            NSColor.black.withAlphaComponent(max(0.25, min(1, dot.alpha * depth))).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    private static let neutral: NSImage = {
        let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) ?? NSImage()
        symbol.isTemplate = true
        return symbol
    }()
}

/// The status item's menu: the worktrees waiting for you (with what the agent
/// asks), then those working (with their task). Choosing one brings teebe
/// forward on it.
struct AgentMenuBarMenu: View {
    let overview: AgentOverviewModel
    @Bindable var display: AgentDisplayPreferences
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let summary = overview.summary
        if summary.waiting.isEmpty && summary.working.isEmpty {
            Text("No agents working or waiting")
        }
        if !summary.waiting.isEmpty {
            Section {
                ForEach(summary.waiting) { item($0, line: display.showsQuestion ? $0.context?.waitingReason : nil) }
            } header: { Text("Waiting for you") }
        }
        if !summary.working.isEmpty {
            Section {
                ForEach(summary.working) { item($0, line: display.showsTask ? task(of: $0) : nil) }
            } header: { Text("Working") }
        }
        Divider()
        Button("Open teebe") { MainWindowOpener.bringForward() }
        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Menu("Show") {
            Toggle(AgentDisplayWording.waitingCountTitle, isOn: $display.showsWaitingCount)
            Toggle(AgentDisplayWording.workingCountTitle, isOn: $display.showsWorkingCount)
            Divider()
            Toggle(AgentDisplayWording.dockTitle, isOn: $display.showsDockIcon)
        }
        Button("Hide Menu Bar Icon") { display.showsMenuBarIcon = false }
    }

    private func task(of entry: AgentOverviewModel.Entry) -> String? {
        WorktreeAgentLines(context: entry.context, mark: .working, options: display.options).task
    }

    /// The worktree and its project, then the agent line, shortened for a menu.
    private func item(_ entry: AgentOverviewModel.Entry, line: String?) -> some View {
        Button {
            Task { await overview.open(entry) }
        } label: {
            Text("\(entry.name)  \(entry.repoTitle)")
            if let line, let short = AgentText.line(line, limit: 70) { Text(short) }
        }
    }
}
