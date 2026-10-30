import Foundation
import ServiceManagement

@MainActor
private final class FakeLoginService: LaunchAtLoginService {
    var status: SMAppService.Status = .notRegistered
    var unavailableReason: String?
    var registrationStatus: SMAppService.Status = .enabled
    var registerError: Error?
    var unregisterError: Error?
    var registerCalls = 0
    var unregisterCalls = 0
    var openCalls = 0
    var pauseUnregister = false
    var unregisterContinuation: CheckedContinuation<Void, Never>?

    func register() async throws {
        registerCalls += 1
        if let registerError { throw registerError }
        status = registrationStatus
    }

    func unregister() async throws {
        unregisterCalls += 1
        if pauseUnregister {
            await withCheckedContinuation { unregisterContinuation = $0 }
        }
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func openLoginItems() { openCalls += 1 }
}

@main
struct LaunchAtLoginTests {
    @MainActor static func main() async {
        await lifecycleAndApproval()
        await failuresAndAvailability()
        await serialUpdates()
        installationValidation()
        print("All launch-at-login tests passed using fakes; no system login items were changed.")
    }

    @MainActor private static func lifecycleAndApproval() async {
        let service = FakeLoginService()
        let controller = LaunchAtLoginController(service: service)
        controller.refresh()
        precondition(controller.status == .notRegistered && !controller.isRequested)
        precondition(controller.canChange && !controller.isUpdating && controller.errorMessage == nil)
        precondition(service.registerCalls == 0 && service.unregisterCalls == 0 && service.openCalls == 0,
                     "Initialization and refresh must not register, unregister, or open System Settings")
        await controller.setEnabled(false)
        precondition(service.unregisterCalls == 0)

        await controller.setEnabled(true)
        precondition(controller.status == .enabled && controller.isRequested)
        precondition(service.registerCalls == 1 && !controller.isUpdating)
        await controller.setEnabled(true)
        precondition(service.registerCalls == 1, "Repeated enable is a no-op")
        await controller.setEnabled(false)
        precondition(controller.status == .notRegistered && !controller.isRequested)
        precondition(service.unregisterCalls == 1)
        await controller.setEnabled(true)
        precondition(controller.status == .enabled && service.registerCalls == 2, "Re-enabling after unregister works")

        let reopened = LaunchAtLoginController(service: service)
        precondition(reopened.isRequested && service.registerCalls == 2,
                     "Existing system registration is preserved, not re-registered")
        service.status = .notRegistered
        reopened.refresh()
        precondition(!reopened.isRequested && service.registerCalls == 2,
                     "System Settings changes win without automatic re-enabling")

        service.registrationStatus = .requiresApproval
        await reopened.setEnabled(true)
        precondition(reopened.needsApproval && reopened.isRequested && reopened.canChange)
        precondition(reopened.statusMessage?.contains("Waiting for approval") == true)
        precondition(service.openCalls == 0, "Approval settings must not open automatically")
        await reopened.setEnabled(true)
        precondition(service.registerCalls == 3, "Pending registration must not be duplicated")
        reopened.openLoginItems()
        precondition(service.openCalls == 1)
        service.status = .enabled
        reopened.refresh()
        precondition(reopened.isRequested && !reopened.needsApproval && reopened.statusMessage == nil)
        reopened.openLoginItems()
        precondition(service.openCalls == 1)
        service.status = .requiresApproval
        reopened.refresh()
        await reopened.setEnabled(false)
        precondition(reopened.status == .notRegistered && !reopened.needsApproval,
                     "Users can cancel a pending approval")
        precondition(service.unregisterCalls == 2)
        print("PASS default off, explicit enable/disable/re-enable, persisted system status, approval and cancellation")
    }

    @MainActor private static func failuresAndAvailability() async {
        let service = FakeLoginService()
        let controller = LaunchAtLoginController(service: service)
        let denied = NSError(domain: "LaunchAtLoginTests", code: 1,
                             userInfo: [NSLocalizedDescriptionKey: "Registration denied"])
        service.registerError = denied
        await controller.setEnabled(true)
        precondition(!controller.isRequested && !controller.isUpdating && controller.canChange)
        precondition(controller.errorMessage?.contains("Could not turn launch at login on: Registration denied") == true)
        controller.refresh()
        precondition(controller.errorMessage != nil, "Refreshing status must not silently erase action errors")
        service.registerError = nil
        await controller.setEnabled(true)
        precondition(controller.isRequested && controller.errorMessage == nil)

        service.unregisterError = denied
        await controller.setEnabled(false)
        precondition(controller.isRequested && !controller.isUpdating && controller.canChange)
        precondition(controller.errorMessage?.contains("Could not turn launch at login off:") == true,
                     "Failed unregister must not pretend the app is disabled")
        service.unregisterError = nil
        await controller.setEnabled(false)
        precondition(!controller.isRequested && controller.errorMessage == nil)

        // The status after an operation, not the requested Boolean, drives the display.
        service.registrationStatus = .notRegistered
        await controller.setEnabled(true)
        precondition(!controller.isRequested)
        service.status = .notFound
        controller.refresh()
        precondition(!controller.canChange && !controller.isRequested && controller.statusMessage != nil)
        let priorRegisterCalls = service.registerCalls
        await controller.setEnabled(true)
        precondition(service.registerCalls == priorRegisterCalls)

        service.status = .notRegistered
        service.unavailableReason = "Development executable is not an installed app."
        controller.refresh()
        precondition(!controller.canChange && controller.statusMessage == service.unavailableReason)
        await controller.setEnabled(true)
        controller.openLoginItems()
        precondition(service.registerCalls == priorRegisterCalls && service.openCalls == 0)
        service.unavailableReason = nil
        service.registrationStatus = .enabled
        await controller.setEnabled(true)
        precondition(controller.isRequested && controller.canChange)

        // A click must use fresh status even if no activation notification has arrived yet.
        service.status = .notRegistered
        await controller.setEnabled(true)
        precondition(service.registerCalls == priorRegisterCalls + 2)
        print("PASS visible errors, status truth after failures, retry, unavailable builds and fresh status on click")
    }

    @MainActor private static func serialUpdates() async {
        let service = FakeLoginService()
        service.status = .enabled
        service.pauseUnregister = true
        let controller = LaunchAtLoginController(service: service)
        let disabling = Task { await controller.setEnabled(false) }
        while service.unregisterContinuation == nil { await Task.yield() }
        precondition(controller.isUpdating && !controller.canChange && controller.isRequested)
        await controller.setEnabled(true)
        await controller.setEnabled(false)
        controller.refresh()
        precondition(controller.isUpdating && service.registerCalls == 0 && service.unregisterCalls == 1,
                     "No overlapping registration while asynchronous unregister is in flight")
        service.unregisterContinuation?.resume()
        service.unregisterContinuation = nil
        await disabling.value
        precondition(!controller.isUpdating && !controller.isRequested && controller.canChange)
        await controller.setEnabled(true)
        precondition(controller.isRequested && service.registerCalls == 1)
        print("PASS asynchronous unregister, disabled transient state, duplicate-action guard, safe re-enable")
    }

    @MainActor private static func installationValidation() {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/synthetic-user/Applications")]
        func issue(_ path: String, identifier: String? = "com.example.Talkless", type: String? = "APPL") -> String? {
            MainAppLaunchAtLoginService.installationIssue(
                bundleURL: URL(fileURLWithPath: path), bundleIdentifier: identifier,
                packageType: type, applicationsDirectories: roots
            )
        }
        for path in ["/Applications/Talkless.app", "/Applications/Utilities/Talkless.app", "/synthetic-user/Applications/Talkless.app"] {
            precondition(issue(path) == nil)
        }
        for path in [
            "/tmp/.build/debug/Talkless", "/tmp/build/Talkless.app",
            "/Volumes/Talkless/Talkless.app", "/synthetic-user/Downloads/Talkless.app",
            "/Applications-other/Talkless.app", "/Applications/../tmp/Talkless.app",
        ] {
            precondition(issue(path) != nil, "Uninstalled builds must show guidance: \(path)")
        }
        precondition(issue("/Applications/Talkless.app", identifier: nil) != nil)
        precondition(issue("/Applications/Talkless.app", identifier: " ") != nil)
        precondition(issue("/Applications/Talkless.app", type: nil) != nil)
        precondition(issue("/Applications/Talkless.bundle") != nil)
        print("PASS installed app validation and graceful development/download/disk image guidance")
    }
}
