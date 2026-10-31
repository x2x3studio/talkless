import AppKit
import AVFoundation
import Combine

/// One app-wide poll of permission state. macOS posts no notification when the user toggles
/// Accessibility or Microphone in System Settings, so views observe this instead of running
/// their own timers, and the app re-enables shortcuts here whenever access returns.
/// Reading status never prompts; prompts stay behind explicit setup guide and Settings actions.
@MainActor
final class PermissionMonitor: ObservableObject {
    static let shared = PermissionMonitor()

    @Published private(set) var accessibilityGranted = DictationController.accessibilityGranted
    @Published private(set) var microphoneStatus = DictationController.microphoneStatus
    /// Called after every refresh while Accessibility is granted.
    var onAccessibilityGranted: (() -> Void)?

    private var timer: Timer?
    private var activation: AnyCancellable?

    func start(interval: TimeInterval = 1.5) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Returning from System Settings should not wait for the next tick.
        activation = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activation = nil
    }

    func refresh() {
        let accessibility = DictationController.accessibilityGranted
        let microphone = DictationController.microphoneStatus
        if accessibility != accessibilityGranted { accessibilityGranted = accessibility }
        if microphone != microphoneStatus { microphoneStatus = microphone }
        if accessibility { onAccessibilityGranted?() }
    }
}
