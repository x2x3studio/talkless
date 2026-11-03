import Combine
import Foundation
import Synchronization
import Testing
@testable import Talkless

@MainActor
@Suite struct AudioInputSettingsTests {
    private static let microphone = AudioInputDevice(id: 1, uid: "test-mic", name: "Test microphone")

    @Test func systemDefaultDeviceIsResolvedOffMainAndTracksChanges() async throws {
        let discovery = AudioInputDeviceDiscovery()
        discovery.activate()
        let microphone = Self.microphone
        let firstTask = discovery.refresh(defaultDevice: {
            #expect(!Thread.isMainThread)
            return 1
        }, using: { [microphone] })
        let first = try #require(firstTask)
        await first.value
        #expect(discovery.hasLoaded && discovery.defaultDeviceID == 1)
        let secondTask = discovery.refresh(defaultDevice: { nil }, using: { [microphone] })
        let second = try #require(secondTask)
        await second.value
        #expect(discovery.defaultDeviceID == nil && discovery.devices == [microphone])
    }

    @Test func slowDiscoveryRunsOffMainAndDropsOverlappingRefreshes() async throws {
        let discovery = AudioInputDeviceDiscovery()
        discovery.activate()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let (started, continuation) = AsyncStream.makeStream(of: Bool.self)
        let microphone = Self.microphone
        let task = try #require(discovery.refresh {
            continuation.yield(Thread.isMainThread)
            continuation.finish()
            guard gate.wait(timeout: .now() + 60) == .success else {
                throw DiscoveryFailure.timeout
            }
            return [microphone]
        })
        var iterator = started.makeAsyncIterator()
        #expect(await iterator.next() == false)
        // Reaching here while the query is blocked proves MainActor remains responsive.
        for _ in 0..<20 {
            #expect(discovery.refresh { Issue.record("Overlapping discovery must be dropped"); return [] } == nil)
        }
        #expect(discovery.devices.isEmpty)
        gate.signal()
        await task.value
        #expect(discovery.devices == [microphone])
        #expect(discovery.error == nil)
        // No queued timer work may overwrite the result after the slow query completes.
        await Task.yield()
        #expect(discovery.devices == [microphone])
        let next = try #require(discovery.refresh { [] })
        await next.value
        #expect(discovery.devices.isEmpty)
    }

    @Test func disappearingInvalidatesResultsWithoutFreeingTheOccupiedSlot() async throws {
        let discovery = AudioInputDeviceDiscovery()
        #expect(discovery.refresh { Issue.record("Hidden view must not query"); return [] } == nil)
        discovery.activate()
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let (started, continuation) = AsyncStream.makeStream(of: Bool.self)
        let microphone = Self.microphone
        let task = try #require(discovery.refresh {
            continuation.yield(true)
            continuation.finish()
            guard gate.wait(timeout: .now() + 60) == .success else {
                throw DiscoveryFailure.timeout
            }
            return [microphone]
        })
        var iterator = started.makeAsyncIterator()
        #expect(await iterator.next() == true)
        discovery.deactivate()
        #expect(discovery.refresh { [] } == nil)
        discovery.activate()
        #expect(discovery.refresh { Issue.record("Reappearing must not overlap discovery"); return [] } == nil)
        gate.signal()
        await task.value
        #expect(discovery.devices.isEmpty, "Results from a previous appearance are ignored")
        #expect(discovery.error == nil)
        let next = try #require(discovery.refresh { [microphone] })
        await next.value
        #expect(discovery.devices == [microphone])
    }

    @Test func errorsRetainDevicesAndRecoveryClearsErrorWithoutRedundantPublishing() async throws {
        let discovery = AudioInputDeviceDiscovery()
        discovery.activate()
        let updates = Mutex<[Bool]>([])
        let observation = discovery.objectWillChange.sink {
            updates.withLock { $0.append(Thread.isMainThread) }
        }
        defer { observation.cancel() }
        let microphone = Self.microphone
        let initial = try #require(discovery.refresh { [microphone] })
        await initial.value
        #expect(updates.withLock { $0 } == [true, true], "First load publishes readiness and devices on the main thread")
        let unchanged = try #require(discovery.refresh { [microphone] })
        await unchanged.value
        #expect(updates.withLock { $0.count } == 2)

        let failure = try #require(discovery.refresh { throw DiscoveryFailure.unavailable })
        await failure.value
        #expect(discovery.devices == [microphone])
        #expect(discovery.error == "Synthetic discovery failure")
        #expect(updates.withLock { $0.count } == 3)
        let repeatedFailure = try #require(discovery.refresh { throw DiscoveryFailure.unavailable })
        await repeatedFailure.value
        #expect(updates.withLock { $0.count } == 3)

        let recovery = try #require(discovery.refresh { [microphone] })
        await recovery.value
        #expect(discovery.error == nil)
        #expect(discovery.devices == [microphone])
        #expect(updates.withLock { $0 } == [true, true, true, true])
        let disconnected = try #require(discovery.refresh { [] })
        await disconnected.value
        #expect(discovery.devices.isEmpty)
        #expect(discovery.error == nil)
    }
}

private enum DiscoveryFailure: LocalizedError {
    case unavailable, timeout

    var errorDescription: String? {
        switch self {
        case .unavailable: "Synthetic discovery failure"
        case .timeout: "Test did not release blocked discovery"
        }
    }
}
