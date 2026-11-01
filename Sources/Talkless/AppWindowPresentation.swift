import AppKit
import OSLog

/// Activate synchronously in the user action, then order the window after menu tracking
/// unwinds; scheduling a default-mode block also needs an explicit run-loop wakeup.
///
/// Cooperative `NSApp.activate()` is routinely refused for this accessory app after a status
/// menu click, and an inactive app's `orderFrontRegardless` window lands *behind* the active
/// app's windows: "visible" to AppKit, hidden from the user until a second attempt.
@MainActor
final class AppWindowPresentation: NSObject {
    private static let shared = AppWindowPresentation()
    private weak var pendingWindow: NSWindow?
    private var requestID = 0
    private let logger = Logger(subsystem: "com.x2x3studio.talkless", category: "WindowPresentation")

    private func record(_ stage: String, window: NSWindow) {
        // Technical state only: never window titles, selected text or credentials.
        logger.notice("\(stage, privacy: .public) request=\(self.requestID) active=\(NSApp.isActive) visible=\(window.isVisible) key=\(window.isKeyWindow) onSpace=\(window.isOnActiveSpace)")
    }

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didActivate),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
        NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
    }

    static func show(_ window: NSWindow) { shared.request(window) }

    /// Explicit user requests to show Talkless UI: take activation instead of asking for it.
    static func activateApp() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func request(_ window: NSWindow) {
        requestID += 1
        let token = requestID
        pendingWindow = window
        record("requested", window: window)
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Activate while still handling the click, not from a later run-loop block.
        Self.activateApp()
        afterMenuTracking { [weak self, weak window] in
            guard let self, let window, self.requestID == token else { return }
            self.order(window)
            if NSApp.isActive { self.pendingWindow = nil }
        }
    }

    private func order(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        // Menu tracking can swallow the first activation; retry once it has unwound.
        Self.activateApp()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        record("ordered", window: window)
    }

    private func afterMenuTracking(_ action: @escaping @MainActor () -> Void) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { action() }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    @objc private func didActivate() {
        guard let window = pendingWindow else { return }
        record("activated", window: window)
        let token = requestID
        afterMenuTracking { [weak self, weak window] in
            guard let self, let window, self.requestID == token else { return }
            self.order(window)
            self.pendingWindow = nil
        }
    }

    @objc private func willClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === pendingWindow else { return }
        requestID += 1
        pendingWindow = nil
    }
}
