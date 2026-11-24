import Testing
@testable import Teebe

@Suite("Clean-up notice lifetime")
struct NoticeLifetimeTests {
    private var ticksToLeave: Int { Int(NoticeLifetime.timeInView / NoticeLifetime.tick) }

    /// How many more ticks in view, unhovered, until it leaves.
    private func ticksLeft(_ lifetime: NoticeLifetime) -> Int {
        var lifetime = lifetime
        var ticks = 1
        while !lifetime.advance(inView: true, hovered: false) { ticks += 1 }
        return ticks
    }

    @Test("it leaves once it has been in view long enough, not before")
    func leavesAfterTimeInView() {
        #expect(ticksLeft(NoticeLifetime()) == ticksToLeave)
        #expect(NoticeLifetime.timeInView >= .seconds(5))
    }

    @Test("time with the window covered or the pointer on it does not count")
    func unseenTimeDoesNotCount() {
        var lifetime = NoticeLifetime()
        for _ in 0..<(ticksToLeave * 3) {
            let leftCovered = lifetime.advance(inView: false, hovered: false)
            let leftHovered = lifetime.advance(inView: true, hovered: true)
            #expect(!leftCovered && !leftHovered)
        }
        #expect(ticksLeft(lifetime) == ticksToLeave)
    }
}
