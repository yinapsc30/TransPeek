import Testing
@testable import TransPeekKit

@Suite("AppIdentity")
struct AppIdentityTests {
    @Test("subsystem 与 App 的 Bundle ID 一致")
    func subsystemMatchesBundleID() {
        #expect(AppIdentity.subsystem == "com.transpeek.app")
    }
}
