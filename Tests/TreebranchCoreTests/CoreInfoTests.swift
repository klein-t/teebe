import Testing
@testable import TreebranchCore

@Suite("CoreInfo")
struct CoreInfoTests {
    @Test("version is non-empty")
    func versionIsSet() {
        #expect(!TreebranchCore.version.isEmpty)
    }
}
