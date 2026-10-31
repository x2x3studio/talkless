import AppKit
import Foundation
import UniformTypeIdentifiers

/// Local, content-free lifecycle breadcrumbs. All mutable file state is confined to `queue`.
/// Never pass transcripts, audio, prompts, credentials, URLs, file paths, or error descriptions.
/// Fatal signals and Objective-C exceptions are left to macOS's crash reporter: Swift is not
/// async-signal-safe, and installing a handler here could hide the original crash.
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()

    private let directory: URL
    private let crashReportsDirectory: URL
    private let maximumFileBytes: Int
    private let queue = DispatchQueue(label: "app.talkless.diagnostics", qos: .utility)
    private let sessionID = UUID().uuidString
    private var handle: FileHandle?
    private var currentBytes = 0
    private var sessionStarted = false
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private var sequence: UInt64 = 0
    private lazy var timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    @MainActor private var exporting = false

    // Fixed names ensure rotation never removes unrelated files from the directory.
    private static let logNames = ["diagnostics.ndjson", "diagnostics.1.ndjson", "diagnostics.2.ndjson"]
    private static let events: Set<String> = [
        "app_start", "app_stop", "session.previous_unclean_exit", "startup_resource_error",
        "hotkey_press", "hotkey_release", "recording_start", "recording_started", "recording_stop", "recording_error",
        "model_load_start", "model_load_complete", "model_error", "recognition_finish", "recognition_complete",
        "paste_attempt", "paste_skipped", "paste_returned", "dictation_cancel",
        "recording_blocked", "recording_stopped", "recording_empty", "permission_blocked",
        "processing_start", "processing_complete", "processing_error", "processing_cancelled",
        "recognition_error", "recognition_empty", "polish_start", "polish_complete", "polish_error",
        "edit_start", "edit_complete", "edit_error",
        "audio_start", "audio_start_configuration", "audio_engine_started", "audio_start_failed",
        "audio_engine_configuration_change", "audio_first_buffer", "audio_recording_summary",
        "audio_interruption", "audio_recovery", "audio_operation_timeout", "audio_engine_reused",
        "diagnostics.export_started", "diagnostics.export_completed", "diagnostics.export_failed",
    ]
    private static let numericKeys: Set<String> = [
        "duration_ms", "sample_rate", "num_channels", "num_samples", "error_code",
        "generation", "report_count", "elapsed_ms", "operation_ms", "startup_ms", "first_buffer_ms",
        "attempt", "channel_count", "common_format", "before_sample_rate", "before_channel_count",
        "before_common_format", "buffer_count", "frame_count", "input_frame_count", "notification_count",
        "hardware_sample_rate", "hardware_channel_count", "before_hardware_sample_rate", "before_hardware_channel_count", "current_device_status", "replacement_count",
    ]
    private static let booleanKeys: Set<String> = [
        "include_crash_reports", "streaming", "cold_start", "hands_free", "polish_enabled", "opposite_finish",
        "empty", "fallback", "explicit_device", "engine_running", "before_engine_running", "interleaved",
        "before_interleaved", "device_changed", "device_available", "format_changed", "audio_delivered", "recovered",
        "resolved_device_available", "route_matches_requested", "formats_compatible", "selected_device_changed", "actual_device_changed",
    ]
    private static let enumValues: [String: Set<String>] = [
        "engine": ["apple", "qwen", "openAICompatible"],
        "model_id": ["Qwen3-ASR-0.6B-4bit", "Qwen3-ASR-1.7B-4bit", "custom"],
        "error_domain": ["NSCocoaErrorDomain", "NSPOSIXErrorDomain", "NSOSStatusErrorDomain", "NSURLErrorDomain", "AVFoundationErrorDomain", "kAFAssistantErrorDomain", "Talkless.TalklessError", "Talkless.ModelManagementError", "unknown"],
        "stage": ["startup", "recording", "recognition", "model_load", "generation", "polish", "edit", "insertion", "shutdown", "processing", "cleanup", "stop"],
        "reason": [
            "user", "escape", "combo", "recorder_interruption", "recognition_error", "stop_interruption",
            "permission", "not_determined", "denied", "restricted", "model_busy", "model_unavailable", "not_configured",
            "unavailable", "invalid_format", "empty_audio", "empty_result", "cancelled", "timeout", "network", "model", "unknown",
            "unchanged", "device_changed", "device_unavailable", "format_changed", "engine_stopped", "no_audio_timeout",
            "conversion_failed", "start_failed", "recovery_exhausted", "configuration_race", "configuration_change", "target_changed", "localization_missing",
            "route_mismatch", "route_unavailable", "native_operation_timeout", "startup_release", "startup_failed", "stop_failed",
        ],
        "mode": ["dictation", "edit", "translation", "hold", "toggle", "hands_free"],
        "recording_mode": ["hold", "toggle"],
        "route_kind": ["direct", "aggregate", "unknown"],
        "state": ["idle", "recording", "processing"],
        "permission": ["microphone", "accessibility"],
    ]

    /// Injectable paths/size allow isolated tests without touching real user logs or crash reports.
    init(directory: URL? = nil, maximumFileBytes: Int = 5_000_000, crashReportsDirectory: URL? = nil) {
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        self.directory = directory ?? library.appendingPathComponent("Application Support/Talkless/Diagnostics", isDirectory: true)
        self.crashReportsDirectory = crashReportsDirectory ?? library.appendingPathComponent("Logs/DiagnosticReports", isDirectory: true)
        self.maximumFileBytes = min(max(maximumFileBytes, 256), 5_000_000)
    }

    func startSession() {
        queue.sync {
            guard !sessionStarted else { return }
            sessionStarted = true
            do {
                try prepareDirectory()
                let marker = directory.appendingPathComponent(".session-active.json")
                if FileManager.default.fileExists(atPath: marker.path) {
                    write(event: "session.previous_unclean_exit", metadata: [:])
                }
                let data = try JSONSerialization.data(withJSONObject: [
                    "session": sessionID,
                    "started_at": timestamp(),
                ], options: [.sortedKeys])
                try data.write(to: marker, options: [.atomic])
            } catch {
                // Diagnostics must never prevent startup, including on read-only/full disks.
            }
            write(event: "app_start", metadata: [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            ])
        }
    }

    func finishSession() {
        queue.sync {
            guard sessionStarted else { return }
            write(event: "app_stop", metadata: [:])
            try? handle?.synchronize()
            try? handle?.close()
            handle = nil
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(".session-active.json"))
            sessionStarted = false
        }
    }

    /// Synchronous checkpoint for main/worker lifecycle calls before native work.
    /// Never call either logging API from the realtime audio tap: even enqueueing allocates.
    func record(event: String, metadata: [String: String] = [:]) {
        guard Self.events.contains(event) else { return }
        let safeMetadata = Self.sanitized(metadata)
        queue.sync { write(event: event, metadata: safeMetadata) }
    }

    /// Nonblocking main/worker logging. The same serial queue orders writes, rotation,
    /// session shutdown and export snapshots; export includes all previously enqueued records.
    func recordAsync(event: String, metadata: [String: String] = [:]) {
        guard Self.events.contains(event) else { return }
        let safeMetadata = Self.sanitized(metadata)
        queue.async { self.write(event: event, metadata: safeMetadata) }
    }

    private static func sanitized(_ metadata: [String: String]) -> [String: String] {
        metadata.filter { key, value in
            guard value.utf8.count <= 64 else { return false }
            if Self.numericKeys.contains(key) {
                return !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 || $0 == 46 }
                    && Double(value).map { $0.isFinite } == true
            }
            if Self.booleanKeys.contains(key) { return value == "true" || value == "false" }
            if key == "version" || key == "build" {
                let infoKey = key == "version" ? "CFBundleShortVersionString" : "CFBundleVersion"
                return value == (Bundle.main.object(forInfoDictionaryKey: infoKey) as? String)
            }
            if key == "operation_id" { return UUID(uuidString: value) != nil }
            return Self.enumValues[key]?.contains(value) == true
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    private func write(event: String, metadata: [String: String]) {
        do {
            sequence += 1
            let elapsed = (DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            var data = try JSONSerialization.data(withJSONObject: [
                "timestamp": timestamp(), "session": sessionID, "event": event, "metadata": metadata,
                "sequence": sequence, "elapsed_ms": elapsed,
            ], options: [.sortedKeys])
            data.append(0x0A)
            guard data.count <= maximumFileBytes else { return }
            try prepareDirectory()
            let current = directory.appendingPathComponent(Self.logNames[0])
            if handle == nil {
                if !FileManager.default.fileExists(atPath: current.path) {
                    guard FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                }
                let opened = try FileHandle(forWritingTo: current)
                handle = opened
                currentBytes = Int(try opened.seekToEnd())
            }
            if currentBytes + data.count > maximumFileBytes {
                try rotate()
                guard FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
                handle = try FileHandle(forWritingTo: current)
                currentBytes = 0
            }
            try handle?.write(contentsOf: data)
            currentBytes += data.count
            // Lifecycle calls are infrequent (never audio-frame callbacks). Persist critical
            // startup/failure and pre-native-work checkpoints, not every ordinary event.
            if event.hasSuffix("failed") || event.hasSuffix("error") || event == "recording_start"
                || event == "model_load_start" || event == "recognition_finish"
                || event == "audio_start" || event == "audio_start_configuration"
                || event == "app_start" || event == "app_stop" || event == "session.previous_unclean_exit" {
                try handle?.synchronize()
            }
        } catch {
            try? handle?.close()
            handle = nil
        }
    }

    private func rotate() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
        let manager = FileManager.default
        let oldest = directory.appendingPathComponent(Self.logNames[2])
        if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
        for index in stride(from: 1, through: 0, by: -1) {
            let source = directory.appendingPathComponent(Self.logNames[index])
            if manager.fileExists(atPath: source.path) {
                try manager.moveItem(at: source, to: directory.appendingPathComponent(Self.logNames[index + 1]))
            }
        }
    }

    @MainActor
    func revealAppLogs() {
        queue.sync { try? prepareDirectory() }
        NSWorkspace.shared.open(directory)
    }

    @MainActor
    func openCrashReports() {
        NSWorkspace.shared.open(crashReportsDirectory)
    }

    @MainActor
    func exportDiagnostics(includeCrashReports: Bool = false) async {
        guard !exporting else { return }
        exporting = true
        defer { exporting = false }
        let panel = NSSavePanel()
        panel.title = L10n.tr("Export Talkless Diagnostics")
        panel.message = includeCrashReports
            ? L10n.tr("Includes original macOS crash reports, which may contain personal information and file paths. Review the ZIP before sharing.")
            : L10n.tr("Exports local event logs and basic system information. No audio, transcripts, credentials, or crash reports.")
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "Talkless-Diagnostics-\(formatter.string(from: Date())).zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try await Task.detached(priority: .utility) {
                try self.exportArchive(to: destination, includeCrashReports: includeCrashReports)
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            let alert = NSAlert()
            alert.messageText = L10n.tr("Could Not Export Diagnostics")
            alert.informativeText = L10n.tr("Check that the destination is writable and has enough free space, then try again.")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Non-UI export entry point. Only explicitly opted-in exports read system crash reports.
    func exportArchive(to destination: URL, includeCrashReports: Bool = false) throws {
        record(event: "diagnostics.export_started", metadata: ["include_crash_reports": String(includeCrashReports)])
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("Talkless-Diagnostics-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        do {
            let bundle = temporary.appendingPathComponent("Talkless-Diagnostics", isDirectory: true)
            let logs = bundle.appendingPathComponent("Logs", isDirectory: true)
            try manager.createDirectory(at: logs, withIntermediateDirectories: true)
            // A consistent snapshot: writes and rotation cannot race the copies.
            try queue.sync {
                try handle?.synchronize()
                for name in Self.logNames {
                    let source = directory.appendingPathComponent(name)
                    if try isRegularFile(source) {
                        try manager.copyItem(at: source, to: logs.appendingPathComponent(name))
                    }
                }
            }
            let summary = Self.systemSummary()
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: bundle.appendingPathComponent("system.json"), options: [.atomic])
            let reportCount = includeCrashReports ? try copyRecentCrashReports(to: bundle) : 0
            let readme = """
            Talkless diagnostics — created locally; nothing is uploaded automatically.

            Logs/ contains up to three rotating NDJSON event logs (5 MB each).
            Events contain millisecond UTC timestamps, session-relative monotonic elapsed_ms,
            and sequence numbers for write ordering (including events within the same millisecond).
            Random session/operation IDs correlate recording, recognition, processing and insertion.
            Allowlisted metadata includes recording mode/generation, cancellation and permission
            reasons, stage durations, numeric audio formats, startup/first-buffer timing, buffer/frame
            totals, and nonidentifying device/engine change flags. Async audio-worker records queued
            before export are included in its snapshot. The realtime audio tap never writes logs.
            Logs do not contain recordings, transcripts, selected text, prompts, credentials,
            endpoints/URLs, error descriptions, device names/UIDs, or response bodies.
            paste_returned records mean the insertion call returned, not that another app
            confirmed receiving text. Wall-clock time can change; use sequence and elapsed_ms
            within a session for ordering, and metadata timings for individual operation stages.
            system.json contains app/OS versions, hardware model, architecture, CPU count,
            and physical memory. It excludes serial numbers, user names, and host names.

            A session.previous_unclean_exit event means Talkless did not finish normally.
            It can also follow Force Quit, power loss, or an interrupted system shutdown;
            it does not prove a crash. The last event helps identify the operation in progress.

            macOS produces native crash backtraces, not this logger. Look for Talkless*.ips
            in ~/Library/Logs/DiagnosticReports using Settings > System > Open Crash Reports.
            Reports may take a little time to appear after a crash. Keep the report matching
            the failure time and app version; exception, termination, and faulting-thread
            frames help locate the crash. No unsafe signal or exception handler is installed.

            Original crash reports included: \(reportCount).
            Crash reports are excluded by default. Opting in includes at most 10 Talkless*.ips
            reports modified in the last 7 days (at most 10 MB each, 25 MB total).
            They can contain personal information, paths, and process details. Review every
            included report before sharing. The absence of a report does not rule out a crash.
            """
            try Data(readme.utf8).write(to: bundle.appendingPathComponent("README.txt"), options: [.atomic])
            let archive = temporary.appendingPathComponent("diagnostics.zip")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", bundle.path, archive.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ExportError.archiveFailed }
            // Atomic write preserves an existing destination if archive creation fails.
            try Data(contentsOf: archive, options: [.mappedIfSafe]).write(to: destination, options: [.atomic])
            record(event: "diagnostics.export_completed", metadata: ["report_count": String(reportCount)])
        } catch {
            record(event: "diagnostics.export_failed")
            throw error
        }
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func copyRecentCrashReports(to bundle: URL) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: crashReportsDirectory.path) else { return 0 }
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let candidates = try manager.contentsOfDirectory(at: crashReportsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        var reports: [(url: URL, date: Date, bytes: Int)] = []
        for url in candidates where url.lastPathComponent.hasPrefix("Talkless") && url.pathExtension == "ips" {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let date = values.contentModificationDate, date >= cutoff,
                  let bytes = values.fileSize, bytes <= 10_000_000 else { continue }
            reports.append((url, date, bytes))
        }
        let target = bundle.appendingPathComponent("CrashReports", isDirectory: true)
        var count = 0
        var totalBytes = 0
        for report in reports.sorted(by: { $0.date > $1.date }).prefix(10) {
            guard totalBytes + report.bytes <= 25_000_000 else { continue }
            if count == 0 { try manager.createDirectory(at: target, withIntermediateDirectories: true) }
            try manager.copyItem(at: report.url, to: target.appendingPathComponent(report.url.lastPathComponent))
            count += 1
            totalBytes += report.bytes
        }
        return count
    }

    private static func systemSummary() -> [String: String] {
        let info = ProcessInfo.processInfo
        let os = info.operatingSystemVersion
        var size = 0
        var model = "unknown"
        if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0, size < 256 {
            var buffer = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 {
                model = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return [
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os_version": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "hardware_model": model,
            "architecture": architecture,
            "processor_count": String(info.processorCount),
            "physical_memory_bytes": String(info.physicalMemory),
        ]
    }

    private enum ExportError: Error { case archiveFailed }
}
