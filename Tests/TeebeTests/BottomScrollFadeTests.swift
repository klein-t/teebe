import AppKit
import SwiftUI
import Testing
@testable import Teebe

@MainActor
@Suite(.serialized)
struct BottomScrollFadeTests {
    @Test func fadesOnlyForRemainingContent() {
        typealias Scroll = BottomFadingScrollView<Text>
        #expect(Scroll.fadeHeight(contentBottom: 200, viewportHeight: 100) == 10)
        #expect(Scroll.fadeHeight(contentBottom: 100, viewportHeight: 100) == 0)
        #expect(Scroll.fadeHeight(contentBottom: 90, viewportHeight: 100) == 0)
        #expect(Scroll.fadeHeight(contentBottom: 104, viewportHeight: 100) == 4)
        #expect(Scroll.fadeHeight(contentBottom: 200, viewportHeight: 0) == 0)
        #expect(Scroll.fadeHeight(contentBottom: 200, viewportHeight: 8) == 4)
    }

    @Test("the mask spans the full width, scrollbar included, and the fade ends at the viewport's bottom")
    func maskCoversTheWholeViewport() {
        typealias Scroll = BottomFadingScrollView<Text>
        let size = CGSize(width: 300, height: 120)
        let layout = Scroll.maskLayout(size: size, fadeHeight: 10)
        #expect(layout.solid == CGRect(x: 0, y: 0, width: 300, height: 110))
        #expect(layout.fade == CGRect(x: 0, y: 110, width: 300, height: 10))
        let none = Scroll.maskLayout(size: size, fadeHeight: 0)
        #expect(none.solid == CGRect(origin: .zero, size: size))
        #expect(none.fade.height == 0)
    }

    @Test func realScrollAndResizeUpdateTheFade() async throws {
        guard NSScreen.main != nil else { return }
        var fade: CGFloat = -1
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 300, height: 100),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: BottomFadingScrollView(content: {
            VStack(spacing: 0) {
                ForEach(0..<20) { index in Text("Row \(index)").frame(height: 24) }
            }
        }, onFadeHeightChange: { fade = $0 }))
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(NSSize(width: 300, height: 100))
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fade == 10)
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { findScroll($0) }.first
        }
        let scroll = try #require(findScroll(host))
        let document = try #require(scroll.documentView)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.bounds.height - scroll.contentView.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fade == 0)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(150))
        #expect(fade == 10)
        window.setContentSize(NSSize(width: 300, height: 600))
        try await Task.sleep(for: .milliseconds(150))
        #expect(fade == 0)
    }
}
