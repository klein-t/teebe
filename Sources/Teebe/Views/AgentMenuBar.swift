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
                                      showsWaiting: display.showsWaitingAgents, showsWorking: display.showsWorkingAgents)
        Image(nsImage: AgentMenuBarImage.render(title))
            .accessibilityLabel(title.accessibilityLabel)
            // This view lives as long as the item, so it can reopen a closed window.
            .onAppear { MainWindowOpener.open = { openWindow(id: WindowID.main) } }
            // The motion runs outside SwiftUI: a frame swaps only the button's image.
            .task(id: AgentMenuBarAnimator.Request(title: title, animates: display.animatesMenuBarIcons)) {
                AgentMenuBarAnimator.shared.configure(title: title, animates: display.animatesMenuBarIcons)
            }
    }
}

/// Draws `AgentMenuBarTitle` as a template image.
@MainActor
enum AgentMenuBarImage {
    static let height: CGFloat = 18
    static let glyphSize: CGFloat = 16
    static let digitGap: CGFloat = 2
    static let segmentGap: CGFloat = 7
    private static let digitFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    static func render(_ title: AgentMenuBarTitle) -> NSImage {
        render(title, orbTime: { _ in ThinkingOrbStyle.staticTime })
    }

    /// One loop of frames for an animated title, drawn once. The loop lasts one
    /// solving cycle at the rows' speed; the ring breathes twice in it, within a
    /// few percent of its speed in the rows, so the loop closes on itself.
    static func frames(_ title: AgentMenuBarTitle, animated: Set<AgentMenuBarAnimation.Orb>,
                       framesPerSecond: Double) -> [NSImage] {
        let loop = ThinkingOrbStyle.phaseSpan / ThinkingOrbStyle(state: .solving).speed
        let count = max(1, Int((loop * framesPerSecond).rounded()))
        return (0..<count).map { index in
            let progress = Double(index) / Double(count)
            return render(title, orbTime: { state in
                switch state {
                case .solving: return animated.contains(.working) ? progress * ThinkingOrbStyle.phaseSpan : ThinkingOrbStyle.staticTime
                case .breathing:
                    return animated.contains(.waiting) ? (2 * progress).truncatingRemainder(dividingBy: 1) * ThinkingOrbStyle.phaseSpan
                        : ThinkingOrbStyle.staticTime
                }
            })
        }
    }

    private static func render(_ title: AgentMenuBarTitle, orbTime: (ThinkingOrbState) -> Double) -> NSImage {
        guard !title.isNeutral else { return neutral }
        let pieces: [(ThinkingOrbState, String)] = title.segments.map { segment in
            switch segment {
            case .waiting(let count): return (.breathing, "\(count)")
            case .working(let count): return (.solving, "\(count)")
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: digitFont, .foregroundColor: NSColor.black]
        let widths = pieces.map { glyphSize + digitGap + ceil(($0.1 as NSString).size(withAttributes: attributes).width) }
        let width = widths.reduce(0, +) + segmentGap * CGFloat(max(0, pieces.count - 1))
        // A bitmap, drawn now: showing a frame is then a copy, never a redraw.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = bitmapImage(size: NSSize(width: width, height: height), scale: scale) {
            var x: CGFloat = 0
            for (index, piece) in pieces.enumerated() {
                drawOrb(piece.0, at: orbTime(piece.0), in: NSRect(x: x, y: (height - glyphSize) / 2, width: glyphSize, height: glyphSize))
                let text = piece.1 as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x + glyphSize + digitGap, y: (height - size.height) / 2), withAttributes: attributes)
                x += widths[index] + segmentGap
            }
        }
        image.isTemplate = true
        return image
    }

    private static func bitmapImage(size: NSSize, scale: CGFloat, draw: () -> Void) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                                         pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        if let bitmap = NSGraphicsContext(bitmapImageRep: rep) {
            // y-down, like the orb geometry and the layout above. The context is
            // marked flipped too, so AppKit draws the digits upright in it.
            bitmap.cgContext.translateBy(x: 0, y: size.height)
            bitmap.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap.cgContext, flipped: true)
            draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// The rows' orb at geometry time `time`, depth as opacity.
    private static func drawOrb(_ state: ThinkingOrbState, at time: Double, in rect: NSRect) {
        let style = ThinkingOrbStyle(state: state)
        let scale = rect.width / ThinkingOrbStyle.size
        for dot in style.frame(at: time) {
            let radius = max(0.6, dot.radius * scale)
            let center = NSPoint(x: rect.minX + dot.x * scale, y: rect.minY + dot.y * scale)
            let depth = 1 - 0.55 * min(1, max(0, dot.white))
            NSColor.black.withAlphaComponent(max(0.25, min(1, dot.alpha * depth))).setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }

    /// The teebe mark, when there is nothing to count.
    private static let neutral: NSImage = teebeGlyph(from: Brand.logo) ?? NSImage(size: NSSize(width: 16, height: height))

    /// The white mark inside the app icon's dark tile, as a template image at
    /// menu bar size: the tile is cropped away and the mark's brightness becomes
    /// opacity, drawn at 1x and 2x so it stays crisp on either screen.
    static func teebeGlyph(from logo: NSImage?, height: CGFloat = 16) -> NSImage? {
        guard let logo, let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        // The mark's bounds in the 1024 px icon, a little padded.
        let unit = CGFloat(source.width) / 1_024
        let markRect = CGRect(x: 180 * unit, y: 236 * unit, width: 670 * unit, height: 606 * unit).integral
        guard let mark = source.cropping(to: markRect) else { return nil }
        let size = NSSize(width: (height * markRect.width / markRect.height).rounded(), height: height)
        let image = NSImage(size: size)
        for scale in [1, 2] {
            let pixelsWide = Int(size.width) * scale, pixelsHigh = Int(size.height) * scale
            guard let gray = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                                       bytesPerRow: pixelsWide, space: CGColorSpaceCreateDeviceGray(),
                                       bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: pixelsWide * 4, bitsPerPixel: 32),
                  let luminance = gray.data, let pixels = rep.bitmapData else { return nil }
            gray.interpolationQuality = .high
            gray.draw(mark, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
            let light = luminance.bindMemory(to: UInt8.self, capacity: pixelsWide * pixelsHigh)
            for index in 0..<(pixelsWide * pixelsHigh) {
                // Black ink, the mark's brightness as opacity: the dark tile drops out.
                pixels[index * 4] = 0
                pixels[index * 4 + 1] = 0
                pixels[index * 4 + 2] = 0
                pixels[index * 4 + 3] = light[index]
            }
            rep.size = size
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }
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
        // The same choices as the title: a kind switched off is not listed either.
        let sections = AgentMenuBarSections(waiting: summary.waiting.count, working: summary.working.count,
                                            showsWaiting: display.showsWaitingAgents, showsWorking: display.showsWorkingAgents)
        if let note = sections.emptyNote {
            Text(note)
        }
        if sections.showsWaiting {
            Section {
                ForEach(summary.waiting) { item($0, line: display.showsQuestion ? $0.context?.waitingReason : nil) }
            } header: { Text("Waiting for you") }
        }
        if sections.showsWorking {
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
            Toggle(AgentDisplayWording.waitingAgentsTitle, isOn: $display.showsWaitingAgents)
            Toggle(AgentDisplayWording.workingAgentsTitle, isOn: $display.showsWorkingAgents)
            Toggle(AgentDisplayWording.animateTitle, isOn: $display.animatesMenuBarIcons)
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
