import AppKit

@MainActor
final class UpdateWindowPlacement: NSObject {
    private weak var sourceWindow: NSWindow?
    private var screenNumber: NSNumber?
    private var fallbackFrame: NSRect?
    private var active = false
    private var showingModalAlert = false
    private var modalTimer: Timer?
    private let positioned = NSHashTable<NSWindow>.weakObjects()
    private let isUpdateWindow: (NSWindow) -> Bool

    init(isUpdateWindow: @escaping (NSWindow) -> Bool) {
        self.isUpdateWindow = isUpdateWindow
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    func begin(sourceWindow: NSWindow?, mouseLocation: NSPoint = NSEvent.mouseLocation) {
        self.sourceWindow = sourceWindow
        let screen = sourceWindow?.screen
            ?? NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        screenNumber = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        fallbackFrame = screen?.visibleFrame
        active = true
        positioned.removeAllObjects()
    }

    func willShowModalAlert() {
        guard active else { return }
        showingModalAlert = true
        modalTimer?.invalidate()
        // NSAlert can become key before AppKit assigns modalWindow. Observe the
        // modal run loop too, without depending on private alert window classes.
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] timer in
            let finished = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return true }
                guard let window = NSApp.modalWindow else { return false }
                self.position(window, isModalWindow: true)
                self.modalTimer = nil
                return true
            }
            if finished { timer.invalidate() }
        }
        modalTimer = timer
        RunLoop.main.add(timer, forMode: .modalPanel)
    }

    func didShowModalAlert() {
        showingModalAlert = false
        modalTimer?.invalidate()
        modalTimer = nil
    }

    func finish() {
        active = false
        didShowModalAlert()
        sourceWindow = nil
        screenNumber = nil
        fallbackFrame = nil
        positioned.removeAllObjects()
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        position(window, isModalWindow: NSApp.modalWindow === window)
    }

    func position(_ window: NSWindow, isModalWindow: Bool = false) {
        guard active, window !== sourceWindow, !positioned.contains(window),
              isUpdateWindow(window) || (showingModalAlert && isModalWindow) else { return }
        let source = sourceWindow.flatMap { $0.isVisible && !$0.isMiniaturized ? $0 : nil }
        let screen = source?.screen
            ?? NSScreen.screens.first { screenNumber != nil && $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == screenNumber }
            ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame ?? fallbackFrame else { return }
        let origin = Self.origin(size: window.frame.size, anchor: source?.frame ?? visibleFrame, visibleFrame: visibleFrame)
        positioned.add(window)
        window.setFrameOrigin(origin)
    }

    static func origin(size: NSSize, anchor: NSRect, visibleFrame: NSRect) -> NSPoint {
        NSPoint(x: max(visibleFrame.minX, min(anchor.midX - size.width / 2, visibleFrame.maxX - size.width)),
                y: max(visibleFrame.minY, min(anchor.midY - size.height / 2, visibleFrame.maxY - size.height)))
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}
