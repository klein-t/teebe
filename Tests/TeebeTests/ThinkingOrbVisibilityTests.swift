import AppKit
import Testing
@testable import Teebe

@MainActor
@Suite("Thinking orb visibility", .serialized)
struct ThinkingOrbVisibilityTests {
    @Test("scrolling an orb out of view stops frame drawing")
    func scrolledOut() {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 60),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        scroll.documentView = document
        window.contentView = scroll
        let orb = ThinkingOrbNSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        document.addSubview(orb)
        #expect(orb.hasVisibleContent)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(!orb.hasVisibleContent)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(orb.hasVisibleContent)
        document.isHidden = true
        #expect(!orb.hasVisibleContent)
    }
}
