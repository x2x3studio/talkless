import AppKit
import Combine
import Sparkle

@MainActor private final class FakeClock {
    final class Tick {
        let interval: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        init(interval: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.action = action
        }
    }
    var ticks: [Tick] = []
    var active: [Tick] { ticks.filter { !$0.cancelled } }
    func schedule(_ interval: TimeInterval, _ action: @escaping @MainActor () -> Void) -> AnyCancellable {
        let tick = Tick(interval: interval, action: action)
        ticks.append(tick)
        return AnyCancellable { tick.cancelled = true }
    }
    func fire() { active.forEach { $0.action() } }
}

@main struct UpdateTests {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "Talkless.UpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func clear() {
            defaults.removePersistentDomain(forName: suite)
            SPUStandardUpdaterController.instances.removeAll()
            SPUUpdater.failStart = false
        }
        let stable = "https://example.invalid/updates/appcast.xml"
        let beta = "https://example.invalid/updates/appcast-beta.xml"
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.talkless.updater",
            "CFBundlePackageType": "APPL",
            "TalklessDefaultUpdateChannel": "beta",
            "SUEnableAutomaticChecks": true,
            "SUAutomaticallyUpdate": false,
            "SUAllowsAutomaticUpdates": false,
            "SUFeedURL": stable,
            "SUBetaFeedURL": beta,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
        ]
        func bundle(_ values: [String: Any], app: Bool = true) throws -> Bundle {
            let url = root.appendingPathComponent(UUID().uuidString + (app ? ".app" : ".bundle"))
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return Bundle(url: url)!
        }
        let configured = try bundle(info)
        func expectError(_ code: Int, _ action: () throws -> Void) {
            do { try action(); preconditionFailure("Expected updater error \(code)") }
            catch { precondition((error as NSError).code == code) }
        }

        clear()
        let clock = FakeClock()
        var busy = false
        let controller = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: clock.schedule, isDictationActive: { busy })
        let sparkle = SPUStandardUpdaterController.instances.last!.updater
        precondition(controller.channel == .beta)
        precondition(controller.automaticallyChecksForUpdates)
        precondition(controller.canChangeAutomaticChecks && controller.canCheckForUpdates)
        precondition(UpdateController.automaticCheckInterval == 1800)
        precondition(clock.active.count == 1 && clock.active[0].interval == 1800)
        precondition(sparkle.backgroundChecks == 0, "No network check just from opening settings/startup")
        precondition(controller.feedURLString(for: sparkle) == beta)
        precondition(controller.allowedChannels(for: sparkle) == ["beta"])
        clock.fire()
        precondition(sparkle.backgroundChecks == 1)

        busy = true
        clock.fire()
        controller.checkForUpdates(nil)
        precondition(sparkle.backgroundChecks == 1 && sparkle.manualChecks == 0)
        precondition(!controller.canCheckForUpdates && controller.status != nil)
        expectError(1) { try controller.updater(sparkle, mayPerform: .updatesInBackground) }
        expectError(1) { try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: nil), updateCheck: .updates) }
        busy = false
        sparkle.sessionInProgress = true
        clock.fire()
        controller.selectChannel(.stable)
        precondition(sparkle.backgroundChecks == 1 && controller.channel == .beta)
        precondition(!controller.canChangeChannel)
        sparkle.sessionInProgress = false
        sparkle.canCheckForUpdates = false
        clock.fire()
        precondition(sparkle.backgroundChecks == 1)
        sparkle.canCheckForUpdates = true

        let cancelledTick = clock.active[0]
        controller.setAutomaticallyChecksForUpdates(false)
        precondition(!controller.automaticallyChecksForUpdates && clock.active.isEmpty && cancelledTick.cancelled)
        cancelledTick.action() // A delivery already queued before cancellation is harmless.
        precondition(sparkle.backgroundChecks == 1)
        expectError(3) { try controller.updater(sparkle, mayPerform: .updatesInBackground) }
        try controller.updater(sparkle, mayPerform: .updates)
        controller.checkForUpdates(nil)
        precondition(sparkle.manualChecks == 1, "Manual checks must work with automatic checks off")
        controller.selectChannel(.stable)
        precondition(controller.channel == .stable && clock.active.isEmpty)
        precondition(sparkle.cycleResets == 0 && sparkle.backgroundChecks == 1)
        precondition(controller.feedURLString(for: sparkle) == stable)
        precondition(controller.allowedChannels(for: sparkle).isEmpty)
        expectError(2) { try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: "beta"), updateCheck: .updates) }
        try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: nil), updateCheck: .updates)
        controller.selectChannel(.beta)
        try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: "beta"), updateCheck: .updates)
        try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: nil), updateCheck: .updates)
        expectError(2) { try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: "nightly"), updateCheck: .updates) }
        precondition(controller.updaterShouldRelaunchApplication(sparkle))

        controller.setAutomaticallyChecksForUpdates(true)
        precondition(clock.active.count == 1)
        controller.setAutomaticallyChecksForUpdates(true)
        precondition(clock.active.count == 1, "Repeated toggles must not duplicate timers")
        controller.selectChannel(.stable)
        precondition(clock.active.count == 1 && sparkle.cycleResets == 0)
        clock.fire()
        precondition(sparkle.backgroundChecks == 2)
        defaults.set(false, forKey: "SUEnableAutomaticChecks") // Sparkle's now-disabled scheduler.
        defaults.set("https://untrusted.invalid/feed", forKey: "SUFeedURL")
        let restartedClock = FakeClock()
        let restarted = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: restartedClock.schedule, isDictationActive: { false })
        precondition(restarted.channel == .stable, "Stored channel overrides bundle Beta default")
        precondition(restarted.automaticallyChecksForUpdates && restartedClock.active.count == 1)
        precondition(restarted.feedURLString(for: sparkle) == stable, "User-default feed overrides must not be trusted")
        restarted.setAutomaticallyChecksForUpdates(false)
        let offClock = FakeClock()
        let off = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: offClock.schedule, isDictationActive: { false })
        precondition(!off.automaticallyChecksForUpdates && offClock.active.isEmpty)
        print("PASS half-hour cadence, toggles, persistence, channels, manual checks, busy/session guards")

        for legacy in [false, true] {
            clear()
            defaults.set(legacy, forKey: "SUEnableAutomaticChecks")
            defaults.set("stable", forKey: "TalklessUpdateChannel")
            let clock = FakeClock()
            let migrated = UpdateController(bundle: configured, defaults: defaults,
                scheduleAutomaticCheck: clock.schedule, isDictationActive: { false })
            precondition(migrated.automaticallyChecksForUpdates == legacy)
            precondition(clock.active.count == (legacy ? 1 : 0))
            precondition(migrated.channel == .stable)
        }
        clear()
        defaults.set("unknown", forKey: "TalklessUpdateChannel")
        let fallback = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(fallback.channel == .beta)
        var noChannelInfo = info
        noChannelInfo.removeValue(forKey: "TalklessDefaultUpdateChannel")
        let stableFallback = UpdateController(bundle: try bundle(noChannelInfo), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(stableFallback.channel == .stable)
        print("PASS legacy automatic-check migration and channel fallback")

        var invalidInfos: [[String: Any]] = []
        for field in ["SUFeedURL", "SUBetaFeedURL", "SUPublicEDKey"] {
            var missing = info
            missing.removeValue(forKey: field)
            invalidInfos.append(missing)
        }
        for invalidURL in ["http://example.invalid/feed", "https://user:pass@example.invalid/feed", "https://example.invalid/feed#fragment", "$(UPDATE_FEED_URL)", "${UPDATE_FEED_URL}", "https:///feed"] {
            var invalid = info
            invalid["SUFeedURL"] = invalidURL
            invalidInfos.append(invalid)
        }
        var invalidKey = info
        invalidKey["SUPublicEDKey"] = Data(repeating: 1, count: 31).base64EncodedString()
        invalidInfos.append(invalidKey)
        for invalid in invalidInfos {
            clear()
            let clock = FakeClock()
            let unavailable = UpdateController(bundle: try bundle(invalid), defaults: defaults,
                scheduleAutomaticCheck: clock.schedule, isDictationActive: { false })
            precondition(SPUStandardUpdaterController.instances.isEmpty)
            precondition(!unavailable.canCheckForUpdates && !unavailable.canChangeAutomaticChecks && !unavailable.canChangeChannel)
            precondition(unavailable.status == "Updates are not configured for this build.")
            precondition(clock.active.isEmpty)
            unavailable.checkForUpdates(nil)
        }
        clear()
        let development = UpdateController(bundle: try bundle(info, app: false), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(!development.canCheckForUpdates && SPUStandardUpdaterController.instances.isEmpty)
        precondition(defaults.object(forKey: "TalklessAutomaticallyChecksForUpdates") == nil,
                     "Unconfigured development builds must not seed a release preference")
        clear()
        SPUUpdater.failStart = true
        let failedClock = FakeClock()
        let failed = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: failedClock.schedule, isDictationActive: { false })
        precondition(!failed.canCheckForUpdates && !failed.canChangeAutomaticChecks)
        precondition(failed.status?.hasPrefix("Updates are unavailable:") == true && failedClock.active.isEmpty)
        print("PASS unconfigured builds, HTTPS/key validation, feed override rejection, startup failure")
        print("All updater tests passed without network, installation, or real preferences.")
    }
}
