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

@MainActor private final class PlacementWindow: NSWindow {
    var visibleForTest = true
    override var isVisible: Bool { visibleForTest }
}

@main struct UpdateTests {
    @MainActor static func testWindowPlacement() {
        _ = NSApplication.shared
        let visible = NSRect(x: -1600, y: 80, width: 1600, height: 900)
        let anchor = NSRect(x: -1300, y: 200, width: 900, height: 600)
        let size = NSSize(width: 400, height: 200)
        precondition(UpdateWindowPlacement.origin(size: size, anchor: anchor, visibleFrame: visible) == NSPoint(x: -1050, y: 400))
        precondition(UpdateWindowPlacement.origin(size: size, anchor: visible, visibleFrame: visible) == NSPoint(x: -1000, y: 430))
        let edge = NSRect(x: -2000, y: -400, width: 100, height: 100)
        precondition(UpdateWindowPlacement.origin(size: size, anchor: edge, visibleFrame: visible) == visible.origin)
        let upperEdge = NSRect(x: 0, y: 1200, width: 100, height: 100)
        precondition(UpdateWindowPlacement.origin(size: size, anchor: upperEdge, visibleFrame: visible) == NSPoint(x: -400, y: 780))
        precondition(UpdateWindowPlacement.origin(size: NSSize(width: 2000, height: 1200), anchor: visible, visibleFrame: visible) == visible.origin)

        let source = PlacementWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        let update = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 300, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        let unrelated = NSWindow(contentRect: NSRect(x: 30, y: 30, width: 200, height: 150), styleMask: [.titled], backing: .buffered, defer: false)
        let modal = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 280, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        let placement = UpdateWindowPlacement { $0 === update }
        let original = update.frame
        placement.position(update)
        precondition(update.frame == original, "No placement outside a user-initiated session")
        placement.begin(sourceWindow: source)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: update)
        let screen = source.screen ?? NSScreen.main!
        precondition(update.frame.origin == UpdateWindowPlacement.origin(size: update.frame.size, anchor: source.frame, visibleFrame: screen.visibleFrame))
        let unrelatedFrame = unrelated.frame
        placement.position(unrelated)
        precondition(unrelated.frame == unrelatedFrame, "Never move another Talkless window")
        update.setFrameOrigin(NSPoint(x: 70, y: 90))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: update)
        precondition(update.frame.origin == NSPoint(x: 70, y: 90), "Refocusing must preserve user placement")
        placement.willShowModalAlert()
        let modalFrame = modal.frame
        placement.position(modal)
        precondition(modal.frame == modalFrame, "Only the active modal window qualifies")
        placement.position(modal, isModalWindow: true)
        precondition(modal.frame.origin == UpdateWindowPlacement.origin(size: modal.frame.size, anchor: source.frame, visibleFrame: screen.visibleFrame))
        placement.didShowModalAlert()
        let alert = NSAlert()
        alert.messageText = "Update placement test"
        placement.willShowModalAlert()
        let modalVisibleFrame = screen.visibleFrame
        let timer = Timer(timeInterval: 0.1, repeats: false) { _ in
            MainActor.assumeIsolated {
                let expected = UpdateWindowPlacement.origin(size: alert.window.frame.size, anchor: source.frame, visibleFrame: modalVisibleFrame)
                precondition(alert.window.frame.origin == expected, "Real NSAlert.runModal must use the source anchor")
                NSApp.abortModal()
            }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        alert.runModal()
        alert.window.orderOut(nil)
        placement.didShowModalAlert()
        placement.finish()
        update.setFrameOrigin(NSPoint(x: 100, y: 100))
        placement.position(update)
        precondition(update.frame.origin == NSPoint(x: 100, y: 100))
        placement.begin(sourceWindow: nil, mouseLocation: NSPoint(x: screen.frame.midX, y: screen.frame.midY))
        placement.position(update)
        precondition(update.frame.origin == UpdateWindowPlacement.origin(size: update.frame.size, anchor: screen.visibleFrame, visibleFrame: screen.visibleFrame))
        placement.finish()
        source.visibleForTest = false
        placement.begin(sourceWindow: source)
        placement.position(update)
        precondition(update.frame.origin == UpdateWindowPlacement.origin(size: update.frame.size, anchor: screen.visibleFrame, visibleFrame: screen.visibleFrame))
        placement.finish()
        print("PASS update placement: settings anchor, menu screen, bounds, modal errors, one-time positioning, session cleanup")
    }

    @MainActor static func main() throws {
        testWindowPlacement()
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
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
            "CFBundleShortVersionString": "0.2.0-beta.1",
            "CFBundleVersion": "42",
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
        let checkDate = Date(timeIntervalSince1970: 1_798_000_000)
        var now = checkDate.addingTimeInterval(60 * 60)
        let controller = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: clock.schedule, now: { now }, isDictationActive: { busy })
        let sparkle = SPUStandardUpdaterController.instances.last!.updater
        precondition(controller.channel == .beta)
        precondition(controller.installedVersion == "0.2.0-beta.1 (build 42)")
        precondition(controller.status == nil, "Configured does not mean up to date")
        precondition(controller.lastUpdateCheckDate == nil && !controller.isUpdateSessionInProgress)
        precondition(controller.checkForUpdatesTitle == "Check for updates…")
        sparkle.lastUpdateCheckDate = checkDate
        precondition(controller.lastUpdateCheckDate == checkDate)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        var stateNotifications = 0
        let stateObservation = controller.objectWillChange.sink { stateNotifications += 1 }
        sparkle.lastUpdateCheckDate = checkDate.addingTimeInterval(1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        precondition(stateNotifications > 0, "Last-check KVO must refresh settings")
        stateObservation.cancel()
        sparkle.lastUpdateCheckDate = checkDate
        precondition(controller.automaticallyChecksForUpdates)
        precondition(controller.canChangeAutomaticChecks && controller.canCheckForUpdates)
        precondition(UpdateController.automaticCheckTick == 1800)
        precondition(UpdateController.automaticCheckInterval(for: .beta) == 6 * 3600
                     && UpdateController.automaticCheckInterval(for: .stable) == 48 * 3600)
        precondition(clock.active.count == 1 && clock.active[0].interval == 1800)
        precondition(sparkle.backgroundChecks == 0, "No network check just from opening settings/startup")
        precondition(controller.feedURLString(for: sparkle) == beta)
        precondition(controller.allowedChannels(for: sparkle) == ["beta"])
        clock.fire()
        precondition(sparkle.backgroundChecks == 0, "Beta waits 6 hours after the last check")
        now = checkDate.addingTimeInterval(7 * 60 * 60)
        clock.fire()
        precondition(sparkle.backgroundChecks == 1)
        controller.updater(sparkle, didFindValidUpdate: SUAppcastItem(channel: nil, displayVersionString: "2.0"))
        precondition(controller.checkForUpdatesTitle == "Update to 2.0…" && controller.makeMenuItem().title == "Update to 2.0…")
        controller.checkForUpdates(nil)
        precondition(sparkle.manualChecks == 1, "Installing a probed update starts a fresh, user-initiated check")
        sparkle.manualChecks = 0
        controller.updaterDidNotFindUpdate(sparkle)
        precondition(controller.availableUpdateVersion == nil && controller.checkForUpdatesTitle == "Check for updates…")

        busy = true
        clock.fire()
        controller.checkForUpdates(nil)
        precondition(sparkle.backgroundChecks == 1 && sparkle.manualChecks == 0)
        precondition(!controller.canCheckForUpdates && controller.status != nil)
        expectError(1) { try controller.updater(sparkle, mayPerform: .updatesInBackground) }
        expectError(1) { try controller.updater(sparkle, shouldProceedWithUpdate: SUAppcastItem(channel: nil), updateCheck: .updates) }
        busy = false
        sparkle.sessionInProgress = true
        precondition(controller.isUpdateSessionInProgress && controller.status?.contains("in progress") == true)
        precondition(controller.checkForUpdatesTitle == "Show update…", "Existing Sparkle windows remain accessible")
        sparkle.canCheckForUpdates = false
        precondition(controller.checkForUpdatesTitle == "Update in progress…")
        sparkle.canCheckForUpdates = true
        clock.fire()
        controller.selectChannel(.stable)
        precondition(sparkle.backgroundChecks == 1 && controller.channel == .beta)
        precondition(!controller.canChangeChannel)
        sparkle.sessionInProgress = false
        sparkle.canCheckForUpdates = false
        clock.fire()
        precondition(sparkle.backgroundChecks == 1)
        sparkle.canCheckForUpdates = true

        let checkFailure = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        controller.updater(sparkle, didFinishUpdateCycleFor: .updatesInBackground, error: checkFailure)
        precondition(controller.lastUpdateError != nil && controller.status?.contains("failed") == true)
        precondition(controller.lastUpdateCheckDate == checkDate, "Failed attempts must not imply up-to-date status")
        try controller.updater(sparkle, mayPerform: .updates)
        precondition(controller.lastUpdateError == nil && controller.status == nil)
        for code in [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError] {
            controller.updater(sparkle, didFinishUpdateCycleFor: .updates,
                error: NSError(domain: SUSparkleErrorDomain, code: Int(code.rawValue)))
            precondition(controller.lastUpdateError == nil && controller.status == nil)
        }
        controller.updater(sparkle, didFinishUpdateCycleFor: .updates, error: checkFailure)
        controller.updater(sparkle, didFinishUpdateCycleFor: .updates, error: nil)
        precondition(controller.lastUpdateError == nil)
        controller.updater(sparkle, didFinishUpdateCycleFor: .updates,
            error: NSError(domain: NSURLErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        precondition(controller.lastUpdateError != nil, "Only Sparkle-domain informational outcomes are excluded")
        controller.selectChannel(.stable)
        precondition(controller.lastUpdateError == nil, "Do not carry errors to a different feed")
        controller.selectChannel(.beta)

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
        precondition(sparkle.backgroundChecks == 1, "Stable waits 48 hours after the last check")
        now = checkDate.addingTimeInterval(49 * 60 * 60)
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
        precondition(defaults.string(forKey: "TalklessUpdateChannel") == "beta")
        var noChannelInfo = info
        noChannelInfo.removeValue(forKey: "TalklessDefaultUpdateChannel")
        let upgradedToStable = UpdateController(bundle: try bundle(noChannelInfo), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(upgradedToStable.channel == .beta, "Installing Stable must preserve Beta enrollment")
        precondition(upgradedToStable.feedURLString(for: sparkle) == beta)
        precondition(upgradedToStable.allowedChannels(for: sparkle) == ["beta"])
        clear()
        let stableFallback = UpdateController(bundle: try bundle(noChannelInfo), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(stableFallback.channel == .stable)
        precondition(defaults.string(forKey: "TalklessUpdateChannel") == "stable")
        let installedBeta = UpdateController(bundle: configured, defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(installedBeta.channel == .stable, "Installing a different channel must not replace saved preference")
        installedBeta.selectChannel(.beta)
        let explicitBeta = UpdateController(bundle: try bundle(noChannelInfo), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(explicitBeta.channel == .beta, "Explicit user choice survives subsequent upgrades")
        print("PASS channel persistence across Beta/Stable packages, explicit choice and fresh-install defaults")

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
        precondition(development.lastUpdateCheckDate == nil && !development.isUpdateSessionInProgress)
        localization.interfaceLanguage = .simplifiedChinese
        precondition(development.status == L10n.tr("Updates are not configured for this build."),
                     "Unavailable status must follow live interface language changes")
        precondition(development.status != "Updates are not configured for this build.")
        localization.interfaceLanguage = .english
        var noVersionInfo = info
        noVersionInfo.removeValue(forKey: "CFBundleVersion")
        let noBuild = UpdateController(bundle: try bundle(noVersionInfo, app: false), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(noBuild.installedVersion == "0.2.0-beta.1")
        noVersionInfo.removeValue(forKey: "CFBundleShortVersionString")
        let noVersion = UpdateController(bundle: try bundle(noVersionInfo, app: false), defaults: defaults,
            scheduleAutomaticCheck: FakeClock().schedule, isDictationActive: { false })
        precondition(noVersion.installedVersion == "Development build")
        print("PASS installed version, live language, last-attempt date KVO, session titles, and error outcomes")
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
