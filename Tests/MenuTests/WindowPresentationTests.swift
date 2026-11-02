import AppKit

/// Real AppKit lifecycle, isolated from the app controller, microphone and user preferences.
@MainActor private final class Target: NSObject {
    var window: NSWindow?
    var creations = 0
    @objc func settings() {
        if window == nil {
            creations += 1
            let created = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 360, height: 200),
                                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.title = "Synthetic Settings"
            window = created
        }
        AppWindowPresentation.show(window!)
    }
}

@main struct WindowPresentationTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let target = Target()
        let menu = NSMenu()
        let item = NSMenuItem(title: "Settings", action: #selector(Target.settings), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        DispatchQueue.main.async {
            // Same target/action as a mouse selection; no app activation or prior window.
            menu.performActionForItem(at: 0)
            let window = target.window!
            precondition(!window.isVisible, "Presentation waits until default run-loop mode")
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
            precondition(!window.isVisible, "Menu tracking must finish before presentation")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                precondition(window.isVisible, "First menu action must show Settings without a second click")
                // Synthetic actions have no user activation token on current macOS. Verify key
                // status when activation is permitted, without forcing a different app inactive.
                if app.isActive { precondition(window.isKeyWindow) }
                precondition(target.creations == 1)
                window.orderOut(nil)
                menu.performActionForItem(at: 0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    precondition(window.isVisible && target.creations == 1,
                                 "Reopening reuses and focuses the same window")
                    window.miniaturize(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        AppWindowPresentation.show(window)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                            precondition(!window.isMiniaturized && window.isVisible,
                                         "Showing a minimized window restores it")
                            window.orderOut(nil)
                            precondition(window.collectionBehavior.contains(.moveToActiveSpace), "Settings follows the user's current desktop")
                            AppWindowPresentation.show(window)
                            window.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                precondition(!window.isVisible, "Closing before deferred presentation cancels that request")
                                print("PASS first presentation, tracking deferral, reuse, minimized restore, active Space and close-before-show")
                                exit(0)
                            }
                        }
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { fatalError("Window presentation test timed out") }
        app.run()
    }
}
