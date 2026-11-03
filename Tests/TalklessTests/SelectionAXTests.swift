import AppKit
import ApplicationServices
import Synchronization
import Testing
@testable import Talkless

/// Synthetic AX nodes only: no Accessibility calls, app activation, keys or clipboard.
struct SelectionAXTests {
    private final class FakeAX: SelectionAXAccess, @unchecked Sendable {
        struct State {
            var calls = 0
            var mainThread = false
            var timeouts: [Float] = []
            var time: TimeInterval = 0
        }
        let state = Mutex(State())
        var selected: String? = "selected"
        var explicitEmpty = false
        var copyEnabled = true
        var cost: TimeInterval = 0
        func application(_ pid: pid_t) -> Int { 0 }
        func setTimeout(_ seconds: Float, on element: Int) -> Bool {
            state.withLock { $0.timeouts.append(seconds); $0.mainThread = $0.mainThread || Thread.isMainThread }
            return true
        }
        func attribute(_ name: String, of element: Int) -> Any? {
            state.withLock { $0.calls += 1; $0.time += cost }
            switch name {
            case kAXFocusedUIElementAttribute: return 1
            case kAXSelectedTextAttribute: return selected
            case kAXSelectedTextRangeAttribute: return explicitEmpty ? CFRange(location: 0, length: 0) : nil
            case kAXMenuBarAttribute: return 2
            case kAXMenuItemCmdCharAttribute: return copyEnabled ? "c" : "x"
            case kAXMenuItemCmdModifiersAttribute: return 0
            case kAXEnabledAttribute: return true
            default: return nil
            }
        }
        func element(from value: Any) -> Int? { value as? Int }
        func children(of element: Int, limit: Int) -> [Int] {
            state.withLock { $0.calls += 1; $0.time += cost }
            return element == 2 ? [99, 3] : Array(repeating: 4, count: limit)
        }
    }

    @Test @MainActor func selectionAndMenuIPCUseBackgroundQueue() async {
        let fake = FakeAX()
        let text = await SelectionAXWorker.run(fallback: TextIO.SelectionReading.unavailable) {
            SelectionAXLookup(access: fake, budget: $0).read(pid: 42)
        }
        let item: Int? = await SelectionAXWorker.run(fallback: nil) {
            SelectionAXLookup(access: fake, budget: $0).copyItem(pid: 42)
        }
        #expect(text == .text("selected"))
        #expect(item == 4)
        #expect(!fake.state.withLock { $0.mainThread })
        #expect(fake.state.withLock { !$0.timeouts.isEmpty && $0.timeouts.allSatisfy { $0 > 0 && $0 <= 0.025 } })
    }

    @Test func menuStopsAtVisitBudget() {
        let fake = FakeAX()
        fake.copyEnabled = false
        let budget = SelectionAXBudget(limits: .init(seconds: 1, visits: 12), deadline: 1,
                                       cancellation: SelectionAXCancellation(), now: { 0 })
        #expect(SelectionAXLookup(access: fake, budget: budget).copyItem(pid: 42) == nil)
        #expect(fake.state.withLock { $0.calls } == 12)
        #expect(fake.state.withLock { $0.timeouts.count } == 12)
    }

    @Test func deadlineDiscardsLateValueAndShrinksTimeout() {
        let fake = FakeAX()
        fake.cost = 0.02
        let budget = SelectionAXBudget(deadline: 0.03, cancellation: SelectionAXCancellation(),
                                       now: { fake.state.withLock { $0.time } })
        #expect(SelectionAXLookup(access: fake, budget: budget).read(pid: 42) == .unavailable)
        let timeouts = fake.state.withLock { $0.timeouts }
        #expect(timeouts.count == 2)
        #expect(abs(timeouts[1] - 0.01) < 0.0001)
        #expect(fake.state.withLock { $0.calls } == 2)
    }

    @Test func cancellationStopsFurtherIPCAndOnlyExplicitRangeMeansEmpty() {
        let fake = FakeAX()
        fake.selected = ""
        let cancellation = SelectionAXCancellation()
        let budget = SelectionAXBudget(deadline: 1, cancellation: cancellation, now: { 0 })
        let lookup = SelectionAXLookup(access: fake, budget: budget)
        #expect(lookup.read(pid: 42) == .unavailable)
        fake.explicitEmpty = true
        #expect(lookup.read(pid: 42) == .empty)
        let count = fake.state.withLock { $0.calls }
        cancellation.cancel()
        #expect(lookup.copyItem(pid: 42) == nil)
        #expect(fake.state.withLock { $0.calls } == count)
    }

    @MainActor private final class Gate {
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func untilWaiting() async { while continuation == nil { await Task.yield() } }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test @MainActor func switchedAppNeverAdoptsAXOrStartsCopyFallback() async {
        for reading in [TextIO.SelectionReading.text("old app"), .unavailable] {
            var pid: pid_t? = 42
            var finds = 0
            let gate = Gate()
            let environment = TextIO.SelectionEnvironment(frontmostPID: { pid }, ownPID: 1,
                read: { target in #expect(target == 42); await gate.wait(); return reading },
                findCopy: { _ in finds += 1; return nil }, postCopy: { _ in Issue.record("Unexpected keys") })
            let task = Task { await TextIO.selectedText(environment: environment) }
            await gate.untilWaiting()
            pid = 43
            gate.release()
            #expect(await task.value == nil)
            #expect(finds == 0)
        }
    }

    @Test @MainActor func cancelledAXNeverAdoptsResultOrStartsFallback() async {
        let gate = Gate()
        var finds = 0
        let environment = TextIO.SelectionEnvironment(frontmostPID: { 42 }, ownPID: 1,
            read: { _ in await gate.wait(); return .unavailable },
            findCopy: { _ in finds += 1; return nil }, postCopy: { _ in Issue.record("Unexpected keys") })
        let task = Task { await TextIO.selectedText(environment: environment) }
        await gate.untilWaiting()
        task.cancel()
        gate.release()
        #expect(await task.value == nil)
        #expect(finds == 0)
    }

    @Test @MainActor func changedTargetOrCancelDuringMenuLookupNeverBorrowsOrPresses() async {
        for cancel in [false, true] {
            let gate = Gate()
            var pid: pid_t? = 42
            var presses = 0
            let environment = TextIO.SelectionEnvironment(frontmostPID: { pid }, ownPID: 1,
                read: { _ in .unavailable },
                findCopy: { target in
                    #expect(target == 42)
                    await gate.wait()
                    return { presses += 1; return true }
                }, postCopy: { _ in Issue.record("Unexpected keys") })
            let task = Task { await TextIO.selectedText(environment: environment) }
            await gate.untilWaiting()
            if cancel { task.cancel() } else { pid = 43 }
            gate.release()
            #expect(await task.value == nil)
            #expect(presses == 0)
        }
    }

    @Test @MainActor func alreadyCancelledWorkerNeverRunsOperation() async {
        let gate = Gate()
        let ran = Mutex(false)
        let task = Task {
            await gate.wait()
            return await SelectionAXWorker.run(fallback: false) { _ in ran.withLock { $0 = true }; return true }
        }
        await gate.untilWaiting()
        task.cancel()
        gate.release()
        #expect(await task.value == false)
        #expect(!ran.withLock { $0 })
    }
}
