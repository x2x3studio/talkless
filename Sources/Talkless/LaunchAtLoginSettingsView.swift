import AppKit
import SwiftUI

/// A standalone section for the System settings form. No registration occurs on creation.
struct LaunchAtLoginSettingsView: View {
    @StateObject private var controller = LaunchAtLoginController()

    var body: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                get: { controller.isRequested },
                set: { enabled in
                    Task { await controller.setEnabled(enabled) }
                }
            ))
            .disabled(!controller.canChange)

            Text("Start Talkless automatically when you log in to your Mac.")
                .font(.caption).foregroundStyle(.secondary)

            if controller.isUpdating {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating login item…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let message = controller.statusMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if controller.needsApproval {
                Button("Open Login Items") { controller.openLoginItems() }
                    .disabled(controller.isUpdating)
            }
            if let error = controller.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear { controller.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}
