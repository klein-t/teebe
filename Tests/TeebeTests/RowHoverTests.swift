import AppKit
import SwiftUI
import Testing
@testable import Teebe

@Suite(.serialized)
@MainActor
struct RowHoverTests {
    @Test func enteringAnotherRowClearsThePreviousHighlightWithoutItsExit() async throws {
        let values = HoverValues()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 104),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(0..<4) { index in
                HoverProbe(index: index, values: values)
                    .frame(width: 300, height: 26)
                    .rowHighlight(isSelected: false)
            }
        }.frame(width: 300, height: 104))
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let rows = anchors(in: hosting).sorted {
            $0.convert($0.bounds, to: nil).midY > $1.convert($1.bounds, to: nil).midY
        }
        try #require(rows.count == 4)
        let event = try hoverEvent()
        // Lazy row updates can lose a prior exit. A new enter must still move
        // the highlight, and a late old exit must not clear the current row.
        for (index, row) in rows.enumerated() {
            row.mouseEntered(with: event)
            try await Task.sleep(for: .milliseconds(30))
            #expect(values.rows[index] == true)
            #expect(values.rows.values.filter { $0 }.count == 1)
        }
        rows[0].mouseExited(with: event)
        try await Task.sleep(for: .milliseconds(30))
        #expect(values.rows[3] == true)
        rows[3].mouseExited(with: event)
        try await Task.sleep(for: .milliseconds(30))
        #expect(values.rows.values.allSatisfy { !$0 })
    }

    @Test func exitAfterNativeReparentingStillClearsSwiftUIState() throws {
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = PointerHoverView(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
        window.contentView?.addSubview(view)
        var hovered = false
        view.onHover = { hovered = $0 }
        let event = try hoverEvent()
        view.mouseEntered(with: event)
        #expect(hovered)
        view.removeFromSuperview()
        view.mouseExited(with: event)
        #expect(!hovered)
    }

    private func anchors(in view: NSView) -> [PointerHoverView] {
        if let row = view as? PointerHoverView { return [row] }
        return view.subviews.flatMap { anchors(in: $0) }
    }

    private func hoverEvent() throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
    }
}

@MainActor
private final class HoverValues {
    var rows: [Int: Bool] = [:]
}

private struct HoverProbe: View {
    let index: Int
    let values: HoverValues
    @Environment(\.rowHovered) private var hovered

    var body: some View {
        Text("File row \(index + 1)")
            .onChange(of: hovered, initial: true) { _, value in values.rows[index] = value }
    }
}
