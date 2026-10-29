import AppKit
import Foundation

@main
struct PreviewProbe {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = ProbeDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        DispatchQueue.main.async { delegate.showWindow() }
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let status = NSTextField(labelWithString: "Local audio plays in real time; the microphone is not recorded.")
    private let output = NSTextView()
    private let start = NSButton(title: "Start Live Preview Test", target: nil, action: nil)
    private let hud = HUDController()
    private var child: Process?
    private var reader: Task<Void, Never>?
    private var logHandle: FileHandle?
    private var sawFinal = false
    private var partialCount = 0

    func showWindow() {
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 740, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Talkless · Qwen Live Preview Test"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Keep the test host a normal app window; only the product HUD floats.
        window.level = .normal
        let content = NSView()
        window.contentView = content
        start.target = self
        start.action = #selector(runProbe)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        output.isEditable = true
        output.isRichText = false
        output.font = NSFont.systemFont(ofSize: 18)
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        scroll.documentView = output
        let note = NSTextField(wrappingLabelWithString: "The overlay reuses the Talkless HUD. This text view should stay empty during input; the final transcript is inserted only after recognition finishes. This tests insertion into this window, not cross-application paste.")
        for view in [start, status, scroll, note] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            start.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            start.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            status.leadingAnchor.constraint(equalTo: start.leadingAnchor),
            status.topAnchor.constraint(equalTo: start.bottomAnchor, constant: 14),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.leadingAnchor.constraint(equalTo: start.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 16),
            scroll.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -16),
            note.leadingAnchor.constraint(equalTo: start.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: status.trailingAnchor),
            note.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20)
        ])
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        print("PREVIEW_WINDOW visible=\(window.isVisible) frame=\(window.frame) screens=\(NSScreen.screens.count)")
        fflush(stdout)
    }

    @objc private func runProbe() {
        guard child == nil else { return }
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else { status.stringValue = "Missing CLI path and arguments"; return }
        output.string = ""
        partialCount = 0
        sawFinal = false
        start.isEnabled = false
        window.makeFirstResponder(output)
        hud.model.preview = ""
        hud.show(.working)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
        let pipe = Pipe()
        process.standardOutput = pipe
        let logPath = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("talkless-preview-probe-\(UUID().uuidString).jsonl")
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logPath)
        status.stringValue = "Preparing model; log: \(logPath.lastPathComponent)"
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.child = nil
                self?.start.isEnabled = true
                if process.terminationStatus != 0 {
                    self?.status.stringValue = "CLI failed with exit code \(process.terminationStatus)"
                    self?.hud.show(.error("Recognition process failed"))
                }
            }
        }
        do {
            try process.run()
            child = process
            let stream = AsyncStream<Data> { continuation in
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if data.isEmpty {
                        handle.readabilityHandler = nil
                        continuation.finish()
                    } else { continuation.yield(data) }
                }
            }
            reader = Task {
                var pending = Data()
                for await data in stream {
                    try? logHandle?.write(contentsOf: data)
                    pending.append(data)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = Data(pending[..<newline])
                        pending.removeSubrange(...newline)
                        consume(line)
                    }
                }
                try? logHandle?.close()
                logHandle = nil
            }
        } catch {
            start.isEnabled = true
            status.stringValue = error.localizedDescription
            hud.show(.error(error.localizedDescription))
        }
    }

    private func consume(_ data: Data) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let kind = event["event"] as? String ?? event["type"] as? String ?? ""
        if kind == "display_update" || kind == "displayUpdate" || kind == "partial" {
            let confirmed = event["confirmedText"] as? String ?? event["confirmed"] as? String ?? ""
            let provisional = event["provisionalText"] as? String ?? event["provisional"] as? String ?? ""
            let text = event["fullText"] as? String ?? event["text"] as? String ?? confirmed + provisional
            guard !text.isEmpty else { return }
            partialCount += 1
            hud.model.preview = text
            hud.show(.listening(handsFree: true))
            status.stringValue = "Preview updates: \(partialCount) · Target empty: \(output.string.isEmpty) · Focus retained: \(window.firstResponder === output)"
        } else if kind == "ended" || kind == "final" {
            let text = event["fullText"] as? String ?? event["text"] as? String ?? ""
            guard !sawFinal else { return }
            sawFinal = true
            output.insertText(text, replacementRange: output.selectedRange())
            status.stringValue = "Done · \(partialCount) preview updates · Final text inserted once into this test view"
            hud.hide()
        } else if kind == "input_stopped" {
            hud.show(.working)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        reader?.cancel()
        if let child, child.isRunning { child.terminate() }
        hud.hide()
    }
}
