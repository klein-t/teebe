import AppKit
import Testing
@testable import Teebe

@Suite(.serialized)
@MainActor
struct HoverTrackingGeometryTests {
    @Test func adjacentRowsHaveDisjointTrackingAreas() throws {
        let window = makeWindow()
        defer { window.close() }
        let rows = (0..<4).map { index in
            PointerHoverView(frame: NSRect(x: 0, y: index * 26, width: 300, height: 26))
        }
        rows.forEach { window.contentView?.addSubview($0) }
        for row in rows {
            row.updateTrackingAreas()
            #expect(row.visibleRect == row.bounds)
        }
        // The previous unclipped anchors all covered the window's content area.
        // Move through rows without relying on any mouseExited callback.
        for index in 0..<4 {
            let pointer = NSPoint(x: 80, y: index * 26 + 13)
            let underPointer = rows.filter { $0.visibleRect.contains($0.convert(pointer, from: nil)) }
            #expect(underPointer.count == 1)
            #expect(underPointer.first === rows[index])
        }
        #expect(!window.isKeyWindow)
        #expect(rows[0].hitTest(NSPoint(x: 80, y: 13)) == nil)
    }

    @Test func stationaryPointerTracksOnlyVisibleRowsAfterScrolling() {
        let window = makeWindow()
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 78))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 260))
        scroll.documentView = document
        window.contentView?.addSubview(scroll)
        let rows = (0..<10).map { index in
            PointerHoverView(frame: NSRect(x: 0, y: index * 26, width: 300, height: 26))
        }
        rows.forEach { document.addSubview($0) }
        for index in 0..<7 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: index * 26))
            scroll.reflectScrolledClipView(scroll.contentView)
            rows.forEach { $0.updateTrackingAreas() }
            let pointer = NSPoint(x: 80, y: 13)
            let underPointer = rows.filter { $0.visibleRect.contains($0.convert(pointer, from: nil)) }
            #expect(underPointer.count == 1)
            #expect(underPointer.first === rows[index])
        }
    }

    @Test func helpAnchorCannotTrackOrDrawAcrossOtherControls() {
        let window = makeWindow()
        defer { window.close() }
        let anchor = HoverHelpView(frame: NSRect(x: 24, y: 26, width: 22, height: 26))
        window.contentView?.addSubview(anchor)
        anchor.updateTrackingAreas()
        #expect(anchor.visibleRect == anchor.bounds)
        #expect(!anchor.visibleRect.contains(anchor.convert(NSPoint(x: 100, y: 39), from: nil)))
        #expect(anchor.visibleRect.contains(anchor.convert(NSPoint(x: 35, y: 39), from: nil)))
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 130),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 130))
        window.orderFront(nil)
        return window
    }
}
