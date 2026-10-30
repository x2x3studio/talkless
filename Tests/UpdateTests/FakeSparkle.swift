// Offline test double. The production controller is also typechecked against real Sparkle.
import AppKit

@MainActor public protocol SPUUpdaterDelegate: AnyObject {}

public let SUSparkleErrorDomain = "SUSparkleErrorDomain"
public enum SUError: Int32 {
    case noUpdateError = 1001
    case installationCanceledError = 4007
    case installationAuthorizeLaterError = 4008
}

public enum SPUUpdateCheck {
    case updates, updatesInBackground, updateInformation
}

@MainActor public final class SUAppcastItem {
    public let channel: String?
    public init(channel: String?) { self.channel = channel }
}

@MainActor public final class SPUUpdater: NSObject {
    @objc dynamic public var canCheckForUpdates = true
    @objc dynamic public var sessionInProgress = false
    @objc dynamic public var lastUpdateCheckDate: Date?
    public var automaticallyChecksForUpdates = true
    public var automaticallyDownloadsUpdates = true
    public var backgroundChecks = 0
    public var manualChecks = 0
    public var cycleResets = 0
    public var started = false
    public static var failStart = false

    public func start() throws {
        precondition(!automaticallyChecksForUpdates, "Sparkle must not run a second scheduler")
        precondition(!automaticallyDownloadsUpdates, "Automatic download/install must remain disabled")
        if Self.failStart { throw NSError(domain: "FakeSparkle", code: 1) }
        started = true
    }

    public func checkForUpdatesInBackground() {
        precondition(started)
        backgroundChecks += 1
    }

    public func resetUpdateCycle() { cycleResets += 1 }
}

@MainActor public final class SPUStandardUpdaterController {
    public static var instances: [SPUStandardUpdaterController] = []
    public let updater = SPUUpdater()

    public init(startingUpdater: Bool, updaterDelegate: SPUUpdaterDelegate?, userDriverDelegate: Any?) {
        precondition(!startingUpdater)
        Self.instances.append(self)
    }

    public func checkForUpdates(_ sender: Any?) { updater.manualChecks += 1 }
}
