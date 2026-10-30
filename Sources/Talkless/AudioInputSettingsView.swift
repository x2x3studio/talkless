import Combine
import SwiftUI

struct AudioInputSettingsView: View {
    @ObservedObject var settings: AppSettings
    var loadDevices: () throws -> [AudioInputDevice] = AudioInputDevices.available
    @State private var devices: [AudioInputDevice] = []
    @State private var discoveryError: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Section("Audio") {
            HStack {
                Picker("Microphone", selection: $settings.audioInputDeviceUID) {
                    Text("System default").tag(nil as String?)
                    ForEach(devices, id: \.uid) { device in
                        Text(label(for: device)).tag(Optional(device.uid))
                    }
                    if let uid = settings.audioInputDeviceUID,
                       !devices.contains(where: { $0.uid == uid }) {
                        Text("Unavailable microphone").tag(Optional(uid))
                    }
                }
                Button("Reset") { settings.audioInputDeviceUID = nil }
                    .disabled(settings.audioInputDeviceUID == nil)
                    .help("Reset microphone to System default. Other settings are unchanged.")
                    .accessibilityLabel("Reset microphone to System default")
            }
            Text("Default: System default. Changes apply to the next recording.")
                .font(.caption).foregroundStyle(.secondary)
            if let discoveryError {
                Text(discoveryError).font(.caption).foregroundStyle(.orange)
            } else if let uid = settings.audioInputDeviceUID,
                      !devices.contains(where: { $0.uid == uid }) {
                Text("The selected microphone is disconnected or unavailable. Reconnect it or choose another microphone; Talkless will not use a different microphone automatically.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        // Poll only while this section is displayed, including while its picker is open.
        // Discovery does not start an engine, request microphone access, or change settings.
        .onAppear(perform: refreshDevices)
        .onReceive(refresh) { _ in refreshDevices() }
    }

    private func label(for device: AudioInputDevice) -> String {
        devices.filter { $0.name == device.name }.count > 1
            ? "\(device.name) (\(device.uid))" : device.name
    }

    private func refreshDevices() {
        do {
            devices = try loadDevices()
            discoveryError = nil
        } catch {
            // Keep the last successful list and the explicit UID during temporary errors.
            discoveryError = error.localizedDescription
        }
    }
}
