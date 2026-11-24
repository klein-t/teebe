import AppKit
import Testing
@testable import Teebe

@MainActor
@Suite("Menu bar moving orbs follow the button")
struct MenuBarOrbOverlayTests {
    private let one = AgentMenuBarImage.Layout(AgentMenuBarTitle(waiting: 0, working: 1, showsWaiting: true, showsWorking: true))
    private let two = AgentMenuBarImage.Layout(AgentMenuBarTitle(waiting: 1, working: 1, showsWaiting: true, showsWorking: true))
    private let padding: CGFloat = 18

    private func frames(_ orb: AgentMenuBarAnimation.Orb, _ scale: CGFloat) -> [CGImage] {
        AgentMenuBarImage.orbFrames(orb.state, framesPerSecond: 2, scale: 1)
    }

    /// Each orb sits where the centered title image leaves room for it.
    private func expectOrbsInPlace(_ overlay: OrbOverlayView, _ layout: AgentMenuBarImage.Layout, in button: NSView) {
        #expect(overlay.frame == button.bounds)
        let left = ((button.bounds.width - layout.size.width) / 2).rounded()
        for piece in layout.pieces {
            #expect(overlay.orbLayers[piece.orb]?.frame.minX == left + piece.orbRect.minX)
            #expect(overlay.orbLayers[piece.orb]?.frame.size == piece.orbRect.size)
        }
    }

    @Test("a second count widens the button after the title is known; the orbs move with it")
    func widening() throws {
        let button = NSView(frame: NSRect(x: 0, y: 0, width: one.size.width + padding, height: 22))
        let overlay = OrbOverlayView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        button.addSubview(overlay)
        overlay.show(one, moving: [.working], in: button, frames: frames)
        expectOrbsInPlace(overlay, one, in: button)

        // The new title arrives while the button still has the old width.
        overlay.show(two, moving: [.waiting, .working], in: button, frames: frames)
        let working = try #require(overlay.orbLayers[.working])
        button.setFrameSize(NSSize(width: two.size.width + padding, height: 22))
        expectOrbsInPlace(overlay, two, in: button)
        // No orb is left on a digit: each one clears the count to its right.
        for piece in two.pieces {
            let orb = try #require(overlay.orbLayers[piece.orb]).frame
            let left = ((button.bounds.width - two.size.width) / 2).rounded()
            #expect(orb.maxX <= left + piece.digitX)
        }
        // Moved, not rebuilt: the motion does not start over.
        #expect(overlay.orbLayers[.working] === working)
    }

    @Test("back to one count the button narrows and the orb follows; stopping forgets the layout")
    func narrowing() {
        let button = NSView(frame: NSRect(x: 0, y: 0, width: two.size.width + padding, height: 22))
        let overlay = OrbOverlayView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        button.addSubview(overlay)
        overlay.show(two, moving: [.waiting, .working], in: button, frames: frames)
        overlay.show(one, moving: [.working], in: button, frames: frames)
        #expect(overlay.orbLayers[.waiting] == nil)
        button.setFrameSize(NSSize(width: one.size.width + padding, height: 22))
        expectOrbsInPlace(overlay, one, in: button)

        overlay.clear()
        button.setFrameSize(NSSize(width: 200, height: 22))
        #expect(overlay.orbLayers.isEmpty)
    }
}
