import AppKit
import SwiftUI
import Testing
@testable import Teebe

@MainActor
@Suite("Agent line selection", .serialized)
struct HoverSlidingLineTests {
    @Test("selection resets a moving line immediately without changing its layout")
    func selectionResetsSlide() async throws {
        let state = SlidingSelectionState()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 180, height: 50),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: SlidingSelectionFixture(state: state))
        view.sizingOptions = []
        window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let initial = try pixels(view)
        let frame = view.frame
        state.hovered = true
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(50))
            if try pixels(view) != initial { break }
        }
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(try pixels(view) != initial) }
        state.selected = true
        try await Task.sleep(for: .milliseconds(40))
        #expect(try pixels(view) == initial)
        #expect(view.frame == frame)
        try await Task.sleep(for: .milliseconds(600))
        #expect(try pixels(view) == initial)
        state.hovered = false
    }

    private func pixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@Observable @MainActor
private final class SlidingSelectionState {
    var selected = false
    var hovered = false
}

private struct SlidingSelectionFixture: View {
    let state: SlidingSelectionState

    var body: some View {
        VStack(spacing: 0) {
            HoverSlidingLine(text: "A long task whose ending needs a hover slide", selection: state.selected)
            HoverSlidingLine(text: "A long question whose ending also needs a hover slide", selection: state.selected)
        }
        .font(.system(size: 12)).foregroundStyle(.black).background(.white)
        .environment(\.rowHovered, state.hovered)
        .frame(width: 180, height: 50)
    }
}
