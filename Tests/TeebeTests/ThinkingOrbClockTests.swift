@testable import Teebe
import Testing

/// An orb's display link runs only while its frames can be seen.
@Suite("Thinking orb clock")
struct ThinkingOrbClockTests {
    @Test("runs for an animating orb in a visible window")
    func runsWhenSeen() {
        #expect(ThinkingOrbClock.runs(animates: true, paused: false, inWindow: true, windowVisible: true))
    }

    @Test("stops for Reduce Motion, low power, no window, or an occluded window")
    func stopsOtherwise() {
        #expect(!ThinkingOrbClock.runs(animates: false, paused: false, inWindow: true, windowVisible: true))
        #expect(!ThinkingOrbClock.runs(animates: true, paused: true, inWindow: true, windowVisible: true))
        #expect(!ThinkingOrbClock.runs(animates: true, paused: false, inWindow: false, windowVisible: false))
        #expect(!ThinkingOrbClock.runs(animates: true, paused: false, inWindow: true, windowVisible: false))
    }

    @Test("keeps the 30 fps cap")
    func frameRate() {
        #expect(ThinkingOrbClock.framesPerSecond == 30)
    }
}
