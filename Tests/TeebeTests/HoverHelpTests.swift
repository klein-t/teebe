import AppKit
import Testing
import SwiftUI
@testable import Teebe

@Suite(.serialized)
@MainActor
struct HoverHelpTests {
    @Test func hoverHighlightsSynchronouslyBeforeTheTooltip() throws {
        let owner = HoverHelpView(frame: NSRect(x: 0, y: 0, width: 22, height: 28))
        owner.text = "Fetch and refresh"
        let event = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil
        ))
        owner.mouseEntered(with: event)
        #expect(owner.highlighted)
        #expect(HoverHelpPresenter.shared.panel == nil)
        owner.mouseExited(with: event)
        #expect(!owner.highlighted)
        #expect(HoverHelpPresenter.shared.owner == nil)
        owner.enabled = false
        owner.mouseEntered(with: event)
        #expect(!owner.highlighted)
    }

    @Test func swiftUIAnchorUsesWindowCoordinates() async throws {
        guard NSScreen.main != nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let hosting = NSHostingView(rootView:
            VStack {
                HStack {
                    Spacer()
                    Text("?").hoverHelp("Untracked file · Not yet added to Git")
                }.frame(height: 30)
                Spacer()
            }.frame(width: 440, height: 600)
        )
        window.contentView = hosting
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(150))
        func find(_ view: NSView) -> HoverHelpView? {
            if let anchor = view as? HoverHelpView { return anchor }
            return view.subviews.lazy.compactMap { find($0) }.first
        }
        let anchor = try #require(find(hosting))
        let rect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        #expect(rect.minY > window.frame.minY + 500)
        let presenter = HoverHelpPresenter()
        defer { presenter.dismiss() }
        presenter.show(owner: anchor, window: window)
        try await Task.sleep(for: .milliseconds(150))
        let panel = try #require(presenter.panel)
        #expect(panel.frame.minY > window.frame.minY + 450)
        #expect(panel.frame.height < 60)
        #expect(abs(rect.minY - panel.frame.maxY - 6) < 1)
    }

    @Test func delayIsShortButNotInstant() {
        #expect(HoverHelpPresenter.delay == .milliseconds(350))
    }

    @Test func placementStaysOnScreen() {
        let screen = NSRect(x: -1200, y: 80, width: 1200, height: 800)
        let size = NSSize(width: 220, height: 42)
        for anchor in [NSRect(x: -1200, y: 80, width: 22, height: 28),
                       NSRect(x: -22, y: 840, width: 22, height: 28)] {
            let frame = HoverHelpPresenter.frame(size: size, anchor: anchor, screen: screen)
            #expect(screen.contains(frame))
            #expect(!frame.intersects(anchor))
        }
    }

    @Test func leavingAnOldControlDoesNotCancelTheNewOne() {
        let presenter = HoverHelpPresenter()
        let first = HoverHelpView()
        let second = HoverHelpView()
        presenter.schedule(owner: first)
        #expect(presenter.panel == nil)
        presenter.schedule(owner: second)
        presenter.dismiss(owner: first)
        #expect(presenter.owner === second)
        presenter.dismiss(owner: second)
        #expect(presenter.owner == nil)
    }

    @Test func cancelledHoverDoesNotAppearLater() async throws {
        let presenter = HoverHelpPresenter()
        let owner = HoverHelpView()
        presenter.schedule(owner: owner)
        presenter.dismiss(owner: owner)
        try await Task.sleep(for: .milliseconds(400))
        #expect(presenter.owner == nil)
        #expect(presenter.panel == nil)
    }

    @Test func anchorDoesNotInterceptClicks() {
        let view = HoverHelpView(frame: NSRect(x: 0, y: 0, width: 24, height: 28))
        #expect(view.hitTest(NSPoint(x: 12, y: 14)) == nil)
    }

    @Test func popupDoesNotResizeOrTakeFocusFromItsWindow() throws {
        guard CGMainDisplayID() != 0 else { return }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 440, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let owner = HoverHelpView(frame: NSRect(x: 20, y: 20, width: 22, height: 28))
        owner.text = "Untracked file · Not yet added to Git"
        window.contentView?.addSubview(owner)
        let originalFrame = window.frame
        let presenter = HoverHelpPresenter()
        defer { presenter.dismiss() }
        presenter.show(owner: owner, window: window)
        let panel = try #require(presenter.panel)
        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow)
        #expect(panel.ignoresMouseEvents)
        #expect(panel.frame.width > 100 && panel.frame.width <= 300)
        #expect(panel.frame.height > 20 && panel.frame.height < 100)
        #expect(window.frame == originalFrame)
        let anchor = window.convertToScreen(owner.convert(owner.bounds, to: nil))
        let screen = try #require(window.screen)
        let expected = HoverHelpPresenter.frame(size: panel.frame.size, anchor: anchor,
                                               screen: screen.visibleFrame)
        #expect(abs(panel.frame.minY - expected.minY) < 1)
        presenter.dismiss()
        #expect(!panel.isVisible)
        owner.text = "Float on top"
        presenter.show(owner: owner, window: window)
        let shortPanel = try #require(presenter.panel)
        #expect(shortPanel.frame.width < 160)
    }

    @Test func windowChangesCancelPendingHelp() {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let owner = HoverHelpView()
        window.contentView?.addSubview(owner)
        let presenter = HoverHelpPresenter()
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMoveNotification,
                     NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            presenter.schedule(owner: owner)
            NotificationCenter.default.post(name: name, object: window)
            #expect(presenter.owner == nil)
        }
    }
}
