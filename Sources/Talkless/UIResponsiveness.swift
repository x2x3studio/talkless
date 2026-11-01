import AppKit
import Foundation

/// Measures how long the main thread takes to answer while Settings is visible, and how often
/// the Settings page re-renders. Records only durations, counts and the page name, so a slow
/// user machine can be diagnosed from exported diagnostics.
@MainActor
final class UIResponsiveness {
    static let shared = UIResponsiveness()
    nonisolated static let stallThreshold: TimeInterval = 0.15
    private static let pingInterval: TimeInterval = 0.1
    private static let renderWindow: TimeInterval = 10
    private static let renderBurst = 60

    /// The Settings page on screen, as a fixed identifier (`SettingsSection.rawValue`).
    var page = "none"
    private var timer: DispatchSourceTimer?
    private var renders = 0
    private var renderWindowStart = Date()
    private let pingQueue = DispatchQueue(label: "app.talkless.responsiveness", qos: .utility)

    /// Call from Settings' body. Cheap; reports bursts that suggest continuous re-rendering.
    nonisolated func noteRender() {
        Task { @MainActor in self.countRender() }
    }

    private func countRender() {
        renders += 1
        let elapsed = Date().timeIntervalSince(renderWindowStart)
        guard elapsed >= Self.renderWindow else { return }
        if renders >= Self.renderBurst {
            Diagnostics.shared.record(event: "settings_renders", metadata: ["count": String(renders), "page": page,
                                                                            "duration_ms": String(Int(elapsed * 1000))])
        }
        renders = 0
        renderWindowStart = Date()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pingQueue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        // A closure written here would inherit main-actor isolation, and Swift traps when the
        // timer then calls it on the ping queue. Use a nonisolated function instead.
        timer.setEventHandler(handler: Self.ping)
        timer.resume()
        self.timer = timer
    }

    /// Runs on the ping queue: time how long the main thread takes to pick up a block.
    nonisolated private static func ping() {
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async {
            let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000_000
            guard lag >= stallThreshold else { return }
            MainActor.assumeIsolated {
                Diagnostics.shared.record(event: "ui_stall", metadata: [
                    "duration_ms": String(Int(lag * 1000)), "page": UIResponsiveness.shared.page,
                ])
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        page = "none"
    }
}
