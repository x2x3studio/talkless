import AppKit
import SwiftUI

/// Value-only presentation shared with the setup guide; macOS remains the source of truth.
struct LaunchAtLoginPresentation: Equatable {
    var isRequested = false
    var isEnabled = false
    var canChange = true
    var isUpdating = false
    var needsApproval = false
    var isUnavailable = false
    var statusMessage: String?
    var errorMessage: String?

    init() {}

    @MainActor init(controller: LaunchAtLoginController) {
        isRequested = controller.isRequested
        isEnabled = controller.status == .enabled && controller.unavailableReason == nil
        canChange = controller.canChange
        isUpdating = controller.isUpdating
        needsApproval = controller.needsApproval
        isUnavailable = controller.unavailableReason != nil
            || ![.enabled, .notRegistered, .requiresApproval].contains(controller.status)
        statusMessage = controller.statusMessage
        errorMessage = controller.errorMessage
    }

    var summary: String {
        if isUnavailable { return L10n.tr("Unavailable") }
        if needsApproval { return L10n.tr("Approval required") }
        return isEnabled ? L10n.tr("Enabled") : L10n.tr("Not enabled")
    }
}

/// Rendering and navigation never call these actions; only the toggle and approval button do.
struct LaunchAtLoginControls: View {
    let presentation: LaunchAtLoginPresentation
    let setEnabled: (Bool) -> Void
    let openLoginItems: () -> Void

    var body: some View {
        Toggle(L10n.tr("Launch at login"), isOn: Binding(
            get: { presentation.isRequested },
            set: { setEnabled($0) }
        ))
        .disabled(!presentation.canChange)

        Text(L10n.tr("Start Talkless automatically when you log in to your Mac."))
            .font(.caption).foregroundStyle(.secondary)

        if presentation.isUpdating {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.tr("Updating login item…")).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let message = presentation.statusMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if presentation.needsApproval {
            Button(L10n.tr("Open Login Items"), action: openLoginItems)
                .disabled(presentation.isUpdating)
        }
        if let error = presentation.errorMessage {
            Text(error).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A standalone section for the System settings form. No registration occurs on creation.
struct LaunchAtLoginSettingsView: View {
    @StateObject private var controller = LaunchAtLoginController()

    var body: some View {
        Section(L10n.tr("Startup")) {
            LaunchAtLoginControls(
                presentation: LaunchAtLoginPresentation(controller: controller),
                setEnabled: { enabled in Task { await controller.setEnabled(enabled) } },
                openLoginItems: controller.openLoginItems
            )
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)) { _ in
            controller.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}
