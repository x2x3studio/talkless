import Foundation
import Testing
@testable import Talkless

@MainActor @Suite(.serialized) struct UIResponsivenessTests {
    /// Regression: the ping handler once inherited main-actor isolation and trapped when the
    /// timer called it on its background queue, crashing Talkless whenever Settings opened.
    @Test func pingsRunOffTheMainThreadWithoutTrapping() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let monitor = fixture.monitor
        monitor.start()
        // The pings fire on their own queue; wait long enough for several.
        try await Task.sleep(for: .milliseconds(350))
        monitor.stop()
        #expect(monitor.page == "none")
    }

    @Test func onlyOneHeartbeatCanBeInFlight() {
        var heartbeat = UIResponsiveness.Heartbeat()
        let session = heartbeat.start()
        let firstPing = heartbeat.begin(session: session)
        #expect(firstPing)
        for _ in 0..<1_000 {
            let duplicateRejected = !heartbeat.begin(session: session)
            #expect(duplicateRejected)
        }
        let acknowledged = heartbeat.finish(session: session)
        #expect(acknowledged)
        let nextPing = heartbeat.begin(session: session)
        #expect(nextPing, "An acknowledgement allows the next ping")
    }

    @Test func stopInvalidatesPendingHeartbeat() {
        var heartbeat = UIResponsiveness.Heartbeat()
        let session = heartbeat.start()
        let pendingPing = heartbeat.begin(session: session)
        #expect(pendingPing)
        heartbeat.stop()
        let stoppedTickRejected = !heartbeat.begin(session: session)
        #expect(stoppedTickRejected)
        let stoppedReplyRejected = !heartbeat.finish(session: session)
        #expect(stoppedReplyRejected, "A stopped session must not report a stall")
    }

    @Test func restartNeitherAccumulatesNorAcceptsStaleHeartbeats() {
        var heartbeat = UIResponsiveness.Heartbeat()
        let oldSession = heartbeat.start()
        let oldPing = heartbeat.begin(session: oldSession)
        #expect(oldPing)
        heartbeat.stop()
        let newSession = heartbeat.start()
        let oldTickRejected = !heartbeat.begin(session: oldSession)
        #expect(oldTickRejected, "Cancelled timer handlers cannot enqueue")
        let newTickDeferred = !heartbeat.begin(session: newSession)
        #expect(newTickDeferred, "The old main block still occupies the slot")
        let oldReplyRejected = !heartbeat.finish(session: oldSession)
        #expect(oldReplyRejected, "The old main block must not report")
        let newPing = heartbeat.begin(session: newSession)
        #expect(newPing)
        let duplicateReplyRejected = !heartbeat.finish(session: oldSession)
        #expect(duplicateReplyRejected)
        let newPingStillPending = !heartbeat.begin(session: newSession)
        #expect(newPingStillPending, "A stale acknowledgement cannot clear the new ping")
        let newReplyAccepted = heartbeat.finish(session: newSession)
        #expect(newReplyAccepted)
    }

    @Test func aStallProducesOneRecordWithTheOriginalDurationAndRecovers() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.monitor.page = "dictation"
        fixture.monitor.start()
        fixture.monitor.start() // Idempotent: no second timer/session.
        fixture.blockMainAcrossSeveralTicks()
        await drainMainQueue()

        let first = try fixture.stalls()
        #expect(first.count == 1)
        let metadata = try #require(first.first?["metadata"] as? [String: String])
        let duration = try #require(metadata["duration_ms"].flatMap(Int.init))
        #expect(duration >= 400, "Skipped ticks must not reset the first ping's timestamp")
        #expect(metadata["page"] == "dictation")

        fixture.blockMainAcrossSeveralTicks()
        await drainMainQueue()
        fixture.monitor.stop()
        #expect(try fixture.stalls().count == 2, "Monitoring resumes after an acknowledged stall")
    }

    @Test func pendingMainCallbackDoesNotReportAfterStopOrRestart() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.monitor.start()
        fixture.blockMainAcrossSeveralTicks()
        fixture.monitor.stop()
        fixture.monitor.page = "dictation"
        fixture.monitor.start()
        // The old callback is still queued; even another stalled session cannot add a ping.
        fixture.blockMainAcrossSeveralTicks()
        await drainMainQueue()
        #expect(try fixture.stalls().isEmpty)

        fixture.blockMainAcrossSeveralTicks()
        await drainMainQueue()
        fixture.monitor.stop()
        #expect(try fixture.stalls().count == 1, "The stale callback must not disable the new session")

        fixture.monitor.start()
        fixture.blockMainAcrossSeveralTicks()
        fixture.monitor.stop()
        await drainMainQueue()
        #expect(try fixture.stalls().count == 1, "Stopping without restarting also discards pending reports")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private struct Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let queue = DispatchQueue(label: "UIResponsivenessTests.ping")
        let diagnostics: Diagnostics
        let monitor: UIResponsiveness

        init() {
            diagnostics = Diagnostics(directory: directory)
            monitor = UIResponsiveness(diagnostics: diagnostics, pingQueue: queue)
        }

        // Deliberately synchronous: the main queue must remain blocked while the real timer fires.
        func blockMainAcrossSeveralTicks() {
            Thread.sleep(forTimeInterval: 0.65)
            queue.sync {} // Ensure already-fired timer handlers finish before draining main.
        }

        func stalls() throws -> [[String: Any]] {
            // A synchronous checkpoint drains preceding async writes before inspecting the file.
            diagnostics.record(event: "settings_renders")
            let data = try Data(contentsOf: directory.appendingPathComponent("diagnostics.ndjson"))
            return try data.split(separator: 0x0A).compactMap { line in
                let record = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
                return record?["event"] as? String == "ui_stall" ? record : nil
            }
        }

        func cleanUp() {
            monitor.stop()
            diagnostics.record(event: "settings_renders")
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
