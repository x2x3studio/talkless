import Combine
import SwiftUI

struct AudioInputSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject var settings: AppSettings
    var loadDevices: @Sendable () throws -> [AudioInputDevice] = AudioInputDevices.available
    @StateObject private var discovery = AudioInputDeviceDiscovery()
    private var devices: [AudioInputDevice] { discovery.devices }
    private var discoveryError: String? { discovery.error }
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Microphone"))
                    Text(L10n.tr("Changes apply to the next recording.")).settingsNote()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker(L10n.tr("Microphone"), selection: $settings.audioInputDeviceUID) {
                    Text(L10n.tr("System default")).tag(nil as String?)
                    ForEach(devices, id: \.uid) { device in
                        Text(label(for: device)).tag(Optional(device.uid))
                    }
                    if let uid = settings.audioInputDeviceUID,
                       !devices.contains(where: { $0.uid == uid }) {
                        Text(L10n.tr("Unavailable microphone")).tag(Optional(uid))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .id(localization.locale.identifier)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: SettingsControlLayout.valueWidth, height: SettingsControlLayout.height)
                Button(L10n.tr("Reset")) { settings.audioInputDeviceUID = nil }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .frame(width: SettingsControlLayout.resetWidth, height: SettingsControlLayout.height)
                    .disabled(settings.audioInputDeviceUID == nil)
                    .help(L10n.tr("Reset microphone to System default. Other settings are unchanged."))
                    .accessibilityLabel(L10n.tr("Reset microphone to System default"))
            }
            .padding(.vertical, 4)
            if let discoveryError {
                Text(discoveryError)
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let uid = settings.audioInputDeviceUID,
                      !devices.contains(where: { $0.uid == uid }) {
                Text(L10n.tr("This microphone is unavailable. Reconnect it or choose another; Talkless won’t switch microphones automatically."))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Poll only while this section is displayed, including while its picker is open.
        // Discovery does not start an engine, request microphone access, or change settings.
        .onAppear {
            discovery.activate()
            refreshDevices()
        }
        .onReceive(refresh) { _ in refreshDevices() }
        .onDisappear { discovery.deactivate() }
    }

    private func label(for device: AudioInputDevice) -> String {
        devices.filter { $0.name == device.name }.count > 1
            ? "\(device.name) (\(device.uid))" : device.name
    }

    private func refreshDevices() {
        discovery.refresh(using: loadDevices)
    }
}

/// The synchronous Core Audio read must neither run on MainActor nor accumulate timer work.
@MainActor
final class AudioInputDeviceDiscovery: ObservableObject {
    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var error: String?
    private var inFlight: Task<Void, Never>?
    private var isActive = false
    private var generation = 0

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        generation &+= 1
        // Core Audio's synchronous call cannot be cancelled. Keep its slot occupied until
        // it actually returns, even if the view disappears and immediately reappears.
    }

    @discardableResult
    func refresh(using loadDevices: @escaping @Sendable () throws -> [AudioInputDevice]) -> Task<Void, Never>? {
        guard isActive, inFlight == nil else { return nil }
        let generation = generation
        let query = Task.detached(priority: .utility) {
            Result { try loadDevices() }
        }
        let completion = Task { [weak self] in
            let result = await query.value
            guard let self else { return }
            self.inFlight = nil
            guard self.isActive, self.generation == generation else { return }
            switch result {
            case .success(let found):
                // Assign only on change: polling must not redraw the whole Dictation page every 2 s.
                if found != self.devices { self.devices = found }
                if self.error != nil { self.error = nil }
            case .failure(let error):
                // Keep the last successful list and the explicit UID during temporary errors.
                let message = error.localizedDescription
                if message != self.error { self.error = message }
            }
        }
        inFlight = completion
        return completion
    }
}
