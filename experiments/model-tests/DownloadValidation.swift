import Foundation

/// Explicitly invoked live-network validation; not part of the offline test runner.
/// Downloads ONLY the default model to the app's real managed root, exercising
/// cancel/recreate-manager/resume, and leaves the verified model for runtime testing.
@main
struct DownloadValidation {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.contains("--download-default-model") else {
            print("No download started. Pass --download-default-model to download the pinned default model into Application Support.")
            return
        }
        let id = ModelCatalog.defaultModelID
        var manager = ModelManager()
        while manager.isChecking { try await Task.sleep(for: .milliseconds(100)) }
        if let existing = manager.installedDirectory(id) {
            print("Already SHA-256 verified: \(existing.path)")
            return
        }
        print("Downloading \(id) to \(manager.rootDirectory.path)")
        manager.install(modelID: id, source: .huggingFace)
        var cancelled = false
        while manager.isBusy {
            if let entry = manager.entry(modelID: id), !cancelled,
               entry.currentFile == "model.safetensors", entry.phase == .downloading,
               entry.downloadedBytes > 12_000_000 {
                print("Cancel requested after \(entry.downloadedBytes) bytes")
                manager.cancel()
                cancelled = true
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard cancelled, manager.entry(modelID: id)?.phase == .paused else {
            throw ModelManagementError.download(manager.error ?? "Expected a paused download; no model was published.")
        }
        // Recreate the manager to exercise on-disk recovery rather than in-memory URLSession state.
        manager = ModelManager()
        while manager.isChecking { try await Task.sleep(for: .milliseconds(100)) }
        guard manager.entry(modelID: id)?.phase == .paused else {
            throw ModelManagementError.download("The new manager did not recover the interrupted download.")
        }
        print("Recovered \(manager.entry(modelID: id)!.downloadedBytes) staged bytes; resuming")
        manager.retry(modelID: id)
        var lastPrinted: Int64 = 0
        while manager.isBusy {
            if let entry = manager.entry(modelID: id), entry.downloadedBytes - lastPrinted > 50_000_000 {
                lastPrinted = entry.downloadedBytes
                print("\(entry.phase.rawValue): \(entry.downloadedBytes)/\(entry.totalBytes)")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        guard let directory = manager.installedDirectory(id) else {
            throw ModelManagementError.download(manager.error ?? "No verified model directory after download.")
        }
        print("PASS: real cancel/restart/resume and SHA-256 verification. Installed: \(directory.path)")
    }
}
