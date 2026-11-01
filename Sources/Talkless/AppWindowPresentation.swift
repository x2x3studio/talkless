import AppKit

/// Present normal app windows after status-menu tracking ends. Application activation is
/// asynchronous: repeat key ordering when activation actually completes, not after a timer.
@MainActor
final class AppWindowPresentation: NSObject {
    private static let shared = AppWindowPresentation()
    private weak var pendingWindow: NSWindow?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(didActivate),
                                               name: NSApplication.didBecomeActiveNotification, object: NSApp)
    }

    static func show(_ window: NSWindow) {
        RunLoop.main.perform(inModes: [.default]) {
            MainActor.assumeIsolated { shared.present(window) }
        }
    }

    private func present(_ window: NSWindow) {
        pendingWindow = window
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        if NSApp.isActive { pendingWindow = nil }
        else { NSApp.activate() }
    }

    @objc private func didActivate() {
        guard let window = pendingWindow else { return }
        pendingWindow = nil
        // Do not reopen a window the user closed before activation completed.
        if window.isVisible { window.makeKeyAndOrderFront(nil) }
    }
}
