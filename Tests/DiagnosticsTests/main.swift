import Foundation

let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
localization.interfaceLanguage = .english
defer { withExtendedLifetime(localization) {} }

// Compiles the actual application logger. Every log/report path is explicitly injected:
// no access to user logs, crash reports, microphones, credentials, or UI is needed.
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        guard try condition() else {
            print("FAIL: \(message)")
            exit(1)
        }
    } catch {
        print("FAIL: \(message) (\(error))")
        exit(1)
    }
}

func events(_ directory: URL) throws -> [[String: Any]] {
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "ndjson" }
    return try files.flatMap { file in
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { line in
            try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
        }
    }
}

func extract(_ archive: URL, into target: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archive.path, target.path]
    try process.run()
    process.waitUntilExit()
    require(process.terminationStatus == 0, "Cannot inspect fixture archive")
}

require(CommandLine.arguments.count == 2, "Expected an isolated fixture directory argument")
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
require(!fm.fileExists(atPath: root.path), "Fixture directory must not already exist")
try fm.createDirectory(at: root, withIntermediateDirectories: false)
let absentReports = root.appendingPathComponent("nonexistent-crash-reports")

let logs = root.appendingPathComponent("logs")
let diagnostic = Diagnostics(directory: logs, crashReportsDirectory: absentReports)
diagnostic.startSession()
diagnostic.startSession()
require(fm.fileExists(atPath: logs.appendingPathComponent(".session-active.json").path), "Session marker missing")
let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: logs.appendingPathComponent(".session-active.json"))) as! [String: String]
require(UUID(uuidString: marker["session"] ?? "") != nil, "Session marker must contain a valid random session ID")
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
require(iso.date(from: marker["started_at"] ?? "") != nil, "Session marker must contain a valid millisecond startup date")
diagnostic.record(event: "recording_start", metadata: [
    "engine": "qwen", "num_channels": "1", "sample_rate": "48000", "error_code": "-50",
    "text": "PRIVATE_TRANSCRIPT", "api_key": "PRIVATE_SECRET", "engine_bad": "PRIVATE",
    "model_id": "/synthetic-private/model", "error_domain": "PRIVATE_DOMAIN", "duration_ms": "PRIVATE_VALUE",
])
diagnostic.record(event: "PRIVATE_TRANSCRIPT")
let filtered = try events(logs)
require(filtered.count == 2, "Unknown events or duplicate startup leaked")
let recorded = filtered.first { $0["event"] as? String == "recording_start" }!
let metadata = recorded["metadata"] as! [String: String]
require(metadata.count == 4 && metadata["engine"] == "qwen", "Metadata allowlist failed")
let logText = try String(contentsOf: logs.appendingPathComponent("diagnostics.ndjson"), encoding: .utf8)
require(!logText.contains("PRIVATE"), "Private content leaked")
require(recorded["session"] as? String == marker["session"], "Log and marker session IDs differ")
diagnostic.finishSession()
require(!fm.fileExists(atPath: logs.appendingPathComponent(".session-active.json").path), "Clean exit did not clear marker")
require(try events(logs).filter { $0["event"] as? String == "app_stop" }.count == 1, "Clean exit event missing")

// Preserve the complete controller/audio-worker contract, but reject all content and identities.
let schemaLogs = root.appendingPathComponent("schema")
let schema = Diagnostics(directory: schemaLogs, crashReportsDirectory: absentReports)
let operationID = UUID().uuidString
let technicalFields = [
    "operation_id": operationID, "generation": "12", "engine": "apple", "mode": "edit",
    "recording_mode": "toggle", "hands_free": "true", "operation_ms": "15", "state": "recording",
    "polish_enabled": "false", "opposite_finish": "true", "empty": "false", "fallback": "true",
    "attempt": "1", "elapsed_ms": "1.25", "startup_ms": "200", "first_buffer_ms": "9",
    "sample_rate": "48000", "channel_count": "2", "common_format": "1",
    "before_sample_rate": "44100", "before_channel_count": "1", "before_common_format": "1",
    "hardware_sample_rate": "48000", "hardware_channel_count": "2",
    "before_hardware_sample_rate": "44100", "before_hardware_channel_count": "1",
    "buffer_count": "3", "frame_count": "1500", "input_frame_count": "4500", "notification_count": "2",
    "duration_ms": "1", "error_code": "-50", "explicit_device": "true", "engine_running": "true",
    "before_engine_running": "false", "interleaved": "false", "before_interleaved": "true",
    "device_changed": "false", "device_available": "true", "format_changed": "false",
    "audio_delivered": "true", "recovered": "true", "stage": "recording", "reason": "unchanged",
]
var unsafeFields = technicalFields
for key in ["text", "transcript", "selected_text", "prompt", "audio", "device_uid", "device_name",
            "url", "endpoint", "path", "api_key", "error_description", "unknown"] {
    unsafeFields[key] = "PRIVATE_CONTENT"
}
schema.recordAsync(event: "audio_start_configuration", metadata: unsafeFields)
schema.record(event: "audio_engine_started") // flushes prior async records without a testing-only API
let schemaEvents = try events(schemaLogs)
require(schemaEvents[0]["metadata"] as? [String: String] == technicalFields, "Technical schema lost allowed fields or retained private ones")
let cancellationReasons = ["escape", "combo", "user", "recorder_interruption", "recognition_error", "stop_interruption"]
let audioReasons = ["unchanged", "device_changed", "device_unavailable", "format_changed", "engine_stopped",
                   "no_audio_timeout", "conversion_failed", "start_failed", "recovery_exhausted", "invalid_format",
                   "unavailable", "configuration_race", "configuration_change", "user"]
for reason in cancellationReasons + audioReasons {
    schema.recordAsync(event: "dictation_cancel", metadata: ["reason": reason])
}
let lifecycleEvents = ["audio_start", "audio_engine_configuration_change", "audio_first_buffer", "audio_recording_summary",
    "audio_interruption", "audio_recovery", "audio_start_failed", "recording_blocked", "recording_stopped", "recording_empty",
    "processing_start", "processing_complete", "processing_error", "processing_cancelled", "recognition_error", "recognition_empty",
    "polish_start", "polish_complete", "polish_error", "edit_start", "edit_complete", "edit_error", "paste_returned"]
for event in lifecycleEvents { schema.recordAsync(event: event) }
schema.record(event: "permission_blocked", metadata: ["permission": "microphone", "reason": "denied"])
schema.record(event: "recording_error", metadata: [
    "operation_id": "PRIVATE_ID", "sample_rate": "nan", "channel_count": "1e9", "num_samples": "--1",
    "duration_ms": "infinity", "generation": "1/2", "engine_running": "TRUE", "stage": "PRIVATE_STAGE",
    "reason": "PRIVATE_REASON", "recording_mode": "PRIVATE_MODE", "state": "PRIVATE_STATE",
    "error_domain": "https://private.example", "error_code": String(repeating: "9", count: 65),
])
let allSchema = try events(schemaLogs)
require(allSchema.last?["metadata"] as? [String: String] == [:], "Invalid or sensitive values survived validation")
let preservedReasons = allSchema.filter { $0["event"] as? String == "dictation_cancel" }
    .compactMap { ($0["metadata"] as? [String: String])?["reason"] }
require(preservedReasons == cancellationReasons + audioReasons, "Distinct cancellation/interruption reasons were lost")
for event in lifecycleEvents { require(allSchema.contains { $0["event"] as? String == event }, "Allowlisted lifecycle event missing") }
for (index, event) in allSchema.enumerated() {
    require(event["sequence"] as? Int == index + 1, "Sequence must preserve FIFO order within a session")
    let timestamp = event["timestamp"] as? String ?? ""
    require(iso.date(from: timestamp) != nil && timestamp.contains("."), "Timestamp lacks milliseconds")
    require(event["elapsed_ms"] as? Int != nil, "Missing numeric monotonic timestamp")
    if index > 0 {
        require((event["elapsed_ms"] as! Int) >= (allSchema[index - 1]["elapsed_ms"] as! Int), "Relative timing moved backwards")
    }
}
let permission = allSchema.first { $0["event"] as? String == "permission_blocked" }!
require((permission["metadata"] as! [String: String]) == ["permission": "microphone", "reason": "denied"], "Permission reason lost")

// Simulate a previous unclean exit without installing unsafe signal handlers.
try Data("{\"session\":\"old-test-session\"}".utf8).write(to: logs.appendingPathComponent(".session-active.json"))
let nextSession = Diagnostics(directory: logs, crashReportsDirectory: absentReports)
nextSession.startSession()
require(try events(logs).filter { $0["event"] as? String == "session.previous_unclean_exit" }.count == 1, "Unclean exit not recorded")
nextSession.finishSession()
let cleanRestart = Diagnostics(directory: logs, crashReportsDirectory: absentReports)
cleanRestart.startSession()
require(try events(logs).filter { $0["event"] as? String == "session.previous_unclean_exit" }.count == 1, "Clean restart falsely reported an unclean exit")
cleanRestart.finishSession()

// Concurrent callers, strict byte limit, and retention touching only owned names.
let rotation = root.appendingPathComponent("rotation")
try fm.createDirectory(at: rotation, withIntermediateDirectories: true)
let unrelated = rotation.appendingPathComponent("user-data.txt")
try Data("keep me".utf8).write(to: unrelated)
let rotating = Diagnostics(directory: rotation, maximumFileBytes: 1024, crashReportsDirectory: absentReports)
rotating.startSession()
DispatchQueue.concurrentPerform(iterations: 200) { index in
    rotating.recordAsync(event: "recording_started", metadata: ["generation": String(index)])
}
rotating.finishSession()
let rotated = try fm.contentsOfDirectory(at: rotation, includingPropertiesForKeys: [.fileSizeKey]).filter { $0.pathExtension == "ndjson" }
require(rotated.count == 3, "Rotation should retain exactly three logs")
for file in rotated {
    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
    require(size <= 1024, "Rotation byte limit exceeded")
}
require(try String(contentsOf: unrelated, encoding: .utf8) == "keep me", "Unrelated file modified")
require(try events(rotation).count > 0, "Concurrent log records corrupt")

// Without rotation, every concurrent record must be retained exactly once.
let concurrentLogs = root.appendingPathComponent("concurrent")
let concurrent = Diagnostics(directory: concurrentLogs, crashReportsDirectory: absentReports)
DispatchQueue.concurrentPerform(iterations: 200) { index in
    concurrent.recordAsync(event: "recording_started", metadata: ["generation": String(index)])
}
concurrent.record(event: "audio_engine_started")
let concurrentEvents = try events(concurrentLogs).filter { $0["event"] as? String == "recording_started" }
require(concurrentEvents.count == 200, "Concurrent callers lost records")
let generations = concurrentEvents.compactMap { ($0["metadata"] as? [String: String])?["generation"] }
require(Set(generations).count == 200, "Concurrent callers duplicated records")

// Disk failure must be non-fatal.
let notDirectory = root.appendingPathComponent("not-a-directory")
try Data("file".utf8).write(to: notDirectory)
let failing = Diagnostics(directory: notDirectory, crashReportsDirectory: absentReports)
failing.startSession()
failing.record(event: "recording_start")
failing.finishSession()

// Entire export coverage uses synthetic reports; never read real OS logs.
let reports = root.appendingPathComponent("mock-crash-reports")
try fm.createDirectory(at: reports, withIntermediateDirectories: true)
try Data("SYNTHETIC_CRASH_BACKTRACE".utf8).write(to: reports.appendingPathComponent("Talkless-recent.ips"))
let old = reports.appendingPathComponent("Talkless-old.ips")
try Data("OLD_REPORT".utf8).write(to: old)
try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-8 * 86400)], ofItemAtPath: old.path)
try Data("OTHER_APP".utf8).write(to: reports.appendingPathComponent("OtherApp.ips"))
try fm.createSymbolicLink(at: reports.appendingPathComponent("Talkless-link.ips"), withDestinationURL: unrelated)
let exporter = Diagnostics(directory: logs, crashReportsDirectory: reports)
let standard = root.appendingPathComponent("standard.zip")
for index in 0..<100 {
    exporter.recordAsync(event: "audio_first_buffer", metadata: ["generation": String(index), "operation_id": operationID])
}
try exporter.exportArchive(to: standard)
let standardExtract = root.appendingPathComponent("standard-extract")
try extract(standard, into: standardExtract)
let standardBundle = standardExtract.appendingPathComponent("Talkless-Diagnostics")
require(!fm.fileExists(atPath: standardBundle.appendingPathComponent("CrashReports").path), "Default export included crash reports")
require(!fm.fileExists(atPath: standardBundle.appendingPathComponent("Logs/.session-active.json").path), "Marker should not be exported")
require(fm.fileExists(atPath: standardBundle.appendingPathComponent("Logs/diagnostics.ndjson").path), "Export omitted application logs")
let exportedEvents = try events(standardBundle.appendingPathComponent("Logs"))
let workerEvents = exportedEvents.filter { $0["event"] as? String == "audio_first_buffer" }
require(workerEvents.count == 100, "Export did not drain previously queued audio-worker events")
require((workerEvents.last?["metadata"] as? [String: String])?["generation"] == "99", "Export changed worker event order")
let exportedReadme = try String(contentsOf: standardBundle.appendingPathComponent("README.txt"), encoding: .utf8)
require(exportedReadme.contains("millisecond UTC") && exportedReadme.contains("device names/UIDs"), "Export explanation omitted timing/privacy contract")
let system = try JSONSerialization.jsonObject(with: Data(contentsOf: standardBundle.appendingPathComponent("system.json"))) as! [String: String]
require(Set(system.keys) == ["app_version", "app_build", "os_version", "hardware_model", "architecture", "processor_count", "physical_memory_bytes"], "Unsafe system-summary fields")
let optedIn = root.appendingPathComponent("with-reports.zip")
try exporter.exportArchive(to: optedIn, includeCrashReports: true)
let reportsExtract = root.appendingPathComponent("reports-extract")
try extract(optedIn, into: reportsExtract)
let exportedReports = try fm.contentsOfDirectory(atPath: reportsExtract.appendingPathComponent("Talkless-Diagnostics/CrashReports").path)
require(exportedReports == ["Talkless-recent.ips"], "Wrong reports included")
let backtrace = try String(contentsOf: reportsExtract.appendingPathComponent("Talkless-Diagnostics/CrashReports/Talkless-recent.ips"), encoding: .utf8)
require(backtrace == "SYNTHETIC_CRASH_BACKTRACE", "Original crash backtrace was not preserved")

// The default path must not inspect the crash-report directory at all.
let excludedExporter = Diagnostics(directory: logs, crashReportsDirectory: notDirectory)
try excludedExporter.exportArchive(to: root.appendingPathComponent("no-report-access.zip"))

print("PASS: session markers, technical schema, sensitive-value rejection, cancellation reasons, millisecond/monotonic sequence timing, async FIFO writes, bounded rotation, write failures, export queue draining, safe summary, and opt-in crash filtering")
