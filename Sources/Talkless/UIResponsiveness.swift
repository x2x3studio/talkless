import AppKit
import Foundation
import Synchronization

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
    private let pingQueue: DispatchQueue
    private let diagnostics: Diagnostics
    nonisolated private let heartbeat = Mutex(Heartbeat())

    init(diagnostics: Diagnostics = .shared,
         pingQueue: DispatchQueue = DispatchQueue(label: "app.talkless.responsiveness", qos: .utility)) {
        self.diagnostics = diagnostics
        self.pingQueue = pingQueue
    }

    /// Protected by `heartbeat`; timer cancellation alone cannot invalidate queued callbacks.
    struct Heartbeat {
        private var session: UUID?
        private var inFlight: UUID?

        mutating func start() -> UUID {
            let session = UUID()
            self.session = session
            return session
        }

        mutating func stop() {
            session = nil
            // Keep the slot occupied until the queued main block drains, even across restarts.
        }

        mutating func begin(session: UUID) -> Bool {
            guard self.session == session, inFlight == nil else { return false }
            inFlight = session
            return true
        }

        mutating func finish(session: UUID) -> Bool {
            guard inFlight == session else { return false }
            inFlight = nil
            return self.session == session
        }
    }

    /// Call from Settings' body. Cheap; reports bursts that suggest continuous re-rendering.
    nonisolated func noteRender() {
        Task { @MainActor in self.countRender() }
    }

    private func countRender() {
        renders += 1
        let elapsed = Date().timeIntervalSince(renderWindowStart)
        guard elapsed >= Self.renderWindow else { return }
        if renders >= Self.renderBurst {
            diagnostics.recordAsync(event: "settings_renders", metadata: ["count": String(renders), "page": page,
                                                                         "duration_ms": String(Int(elapsed * 1000))])
        }
        renders = 0
        renderWindowStart = Date()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: pingQueue)
        timer.schedule(deadline: .now() + Self.pingInterval, repeating: Self.pingInterval)
        let session = heartbeat.withLock { $0.start() }
        // Construct the handler outside main-actor isolation: it runs on the ping queue.
        timer.setEventHandler(handler: pingHandler(session: session))
        timer.resume()
        self.timer = timer
    }

    nonisolated private func pingHandler(session: UUID) -> @Sendable () -> Void {
        { [weak self] in self?.ping(session: session) }
    }

    /// Keep the first unanswered ping's timestamp: skipped ticks must not shorten a stall.
    nonisolated private func ping(session: UUID) {
        guard heartbeat.withLock({ $0.begin(session: session) }) else { return }
        let sent = DispatchTime.now().uptimeNanoseconds
        DispatchQueue.main.async { [weak self] in
            let lag = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000_000
            guard let self, self.heartbeat.withLock({ $0.finish(session: session) }) else { return }
            guard lag >= Self.stallThreshold else { return }
            self.diagnostics.recordAsync(event: "ui_stall", metadata: [
                "duration_ms": String(Int(lag * 1000)), "page": self.page,
            ])
        }
    }

    func stop() {
        heartbeat.withLock { $0.stop() }
        timer?.cancel()
        timer = nil
        page = "none"
    }
}
