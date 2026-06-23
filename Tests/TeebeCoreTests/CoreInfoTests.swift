import Testing
@testable import TeebeCore

@Suite("CoreInfo")
struct CoreInfoTests {
    @Test("version is non-empty")
    func versionIsSet() {
        #expect(!TeebeCore.version.isEmpty)
    }
}
