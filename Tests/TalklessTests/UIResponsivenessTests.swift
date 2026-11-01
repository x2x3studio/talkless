import Foundation
import Testing
@testable import Talkless

@MainActor @Suite struct UIResponsivenessTests {
    /// Regression: the ping handler once inherited main-actor isolation and trapped when the
    /// timer called it on its background queue, crashing Talkless whenever Settings opened.
    @Test func pingsRunOffTheMainThreadWithoutTrapping() async throws {
        let monitor = UIResponsiveness.shared
        monitor.start()
        // The pings fire on their own queue; wait long enough for several.
        try await Task.sleep(for: .milliseconds(350))
        monitor.stop()
        #expect(monitor.page == "none")
    }
}
