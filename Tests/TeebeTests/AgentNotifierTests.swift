import Testing
import UserNotifications
@testable import Teebe

@Suite("Agent notifier")
struct AgentNotifierTests {
    @Test("notifications still show as banners while Teebe is the frontmost app")
    func foregroundPresentation() {
        #expect(AgentNotifier.foregroundPresentation == [.banner, .sound, .list])
    }
}
