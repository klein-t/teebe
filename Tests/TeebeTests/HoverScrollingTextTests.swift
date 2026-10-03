import AppKit
import SwiftUI
import Testing
@testable import Teebe

@MainActor
@Suite("Hover label layout", .serialized)
struct HoverScrollingTextTests {
    @Test("long labels scroll inside a fixed row and restore after leaving", arguments: [false, true])
    func longLabel(showsFullNameHelp: Bool) async throws {
        let state = HoverLabelState()
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 180, height: 30),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSHostingView(rootView: HoverLabelFixture(state: state, showsFullNameHelp: showsFullNameHelp))
        view.sizingOptions = []
        window.contentView = view
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        let frame = view.frame
        let initial = try pixels(view)
        state.hovered = true
        try await Task.sleep(for: .milliseconds(200))
        let start = try pixels(view)
        try await Task.sleep(for: .milliseconds(700))
        let scrolled = try pixels(view)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { #expect(start != scrolled) }
        #expect(view.frame == frame)
        state.hovered = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(try pixels(view) == initial)
        #expect(view.frame == frame)

    }

    private func pixels(_ view: NSView) throws -> Data {
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

@Observable @MainActor
private final class HoverLabelState {
    var hovered = false
}

private struct HoverLabelFixture: View {
    var state: HoverLabelState
    var showsFullNameHelp: Bool
    var body: some View {
        HoverScrollingText(text: "A deliberately long file name with a distinct ending.swift",
                           showsFullNameHelp: showsFullNameHelp)
            .font(.system(size: 13))
            .frame(width: 180, height: 30)
            .foregroundStyle(.black).background(.white)
            .environment(\.rowHovered, state.hovered)
    }
}
