import Combine
import Foundation
import ServiceManagement

/// Reading status must not register the app or open System Settings.
@MainActor
protocol LaunchAtLoginService {
    var status: SMAppService.Status { get }
    var unavailableReason: String? { get }
    func register() async throws
    func unregister() async throws
    func openLoginItems()
}

@MainActor
struct MainAppLaunchAtLoginService: LaunchAtLoginService {
    private let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    var unavailableReason: String? {
        Self.installationIssue(
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier,
            packageType: bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String
        )
    }

    var status: SMAppService.Status {
        // A swift run executable or a build/download copy is not an installed login item.
        guard unavailableReason == nil else { return .notFound }
        return SMAppService.mainApp.status
    }

    func register() async throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        // Wait for completion before allowing a subsequent registration.
        try await SMAppService.mainApp.unregister()
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func installationIssue(
        bundleURL: URL,
        bundleIdentifier: String?,
        packageType: String?,
        applicationsDirectories: [URL] = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    ) -> String? {
        guard bundleURL.pathExtension.lowercased() == "app", packageType == "APPL",
              let bundleIdentifier, !bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Launch at login is unavailable in this development build. Install and open Talkless.app from Applications."
        }
        let components = bundleURL.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let installed = applicationsDirectories.contains { directory in
            let root = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return components.count > root.count && components.starts(with: root)
        }
        guard installed else {
            return "Move Talkless to Applications (or your home folder’s Applications folder), then reopen it to use launch at login."
        }
        return nil
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var unavailableReason: String?
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    private let service: any LaunchAtLoginService

    init(service: any LaunchAtLoginService = MainAppLaunchAtLoginService()) {
        self.service = service
        status = service.status
        unavailableReason = service.unavailableReason
    }

    /// Pending approval is a registered request, not a successfully enabled login item.
    var isRequested: Bool { status == .enabled || status == .requiresApproval }

    var canChange: Bool {
        guard unavailableReason == nil, !isUpdating else { return false }
        switch status {
        case .enabled, .requiresApproval, .notRegistered: return true
        case .notFound: return false
        @unknown default: return false
        }
    }

    var needsApproval: Bool { unavailableReason == nil && status == .requiresApproval }

    var statusMessage: String? {
        if let unavailableReason { return unavailableReason }
        switch status {
        case .enabled: return nil
        case .notRegistered: return nil
        case .requiresApproval:
            return "Waiting for approval in System Settings. Talkless will not open at login until you allow it."
        case .notFound:
            return "macOS could not find this app’s login item. Reinstall Talkless in Applications and try again."
        @unknown default:
            return "Launch at login is unavailable. Check Login Items in System Settings."
        }
    }

    /// Opening settings or returning from System Settings only reads macOS's current state.
    func refresh() {
        status = service.status
        unavailableReason = service.unavailableReason
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        // Account for changes made in System Settings since the last activation.
        refresh()
        guard canChange, enabled != isRequested else { return }
        errorMessage = nil
        isUpdating = true
        defer {
            refresh()
            isUpdating = false
        }
        do {
            if enabled {
                try await service.register()
            } else {
                try await service.unregister()
            }
        } catch {
            errorMessage = "Could not turn launch at login \(enabled ? "on" : "off"): \(error.localizedDescription)"
        }
    }

    func openLoginItems() {
        guard needsApproval, !isUpdating else { return }
        service.openLoginItems()
    }
}
