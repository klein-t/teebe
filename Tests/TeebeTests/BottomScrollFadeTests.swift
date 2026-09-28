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
