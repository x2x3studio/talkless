import AppKit
import OSLog

/// Ask for activation synchronously in the user action, then order the window after menu
/// tracking unwinds. Deferring the activation request itself can lose the click's activation
/// opportunity; scheduling a default-mode block also needs an explicit run-loop wakeup.
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

    private func request(_ window: NSWindow) {
        requestID += 1
        let token = requestID
        pendingWindow = window
        record("requested", window: window)
        window.collectionBehavior.remove(.canJoinAllSpaces)
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Request while still handling the click, not from a later run-loop block.
        NSApp.activate()
        afterMenuTracking { [weak self, weak window] in
            guard let self, let window, self.requestID == token else { return }
            self.order(window)
            if NSApp.isActive { self.pendingWindow = nil }
        }
    }

    private func order(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
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
