import Foundation
import Combine

enum ModelPhase: String, Sendable {
    case checking, notInstalled, downloading, verifying, paused, installed, failed, deleting
}

struct ModelEntry: Identifiable, Sendable {
    let model: CatalogModel
    var phase: ModelPhase = .checking
    var downloadedBytes: Int64 = 0
    var error: String?
    var currentFile: String?
    var source: ModelDownloadSource?
    var id: String { model.id }
    var totalBytes: Int64 { model.totalBytes }
    var progress: Double { totalBytes > 0 ? min(1, max(0, Double(downloadedBytes) / Double(totalBytes))) : 0 }
}

@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()
    static var defaultRootDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless/Models", isDirectory: true)
    }

    @Published private(set) var entries: [ModelEntry]
    /// The selected managed model, not a claim that weights are installed or loaded.
    @Published private(set) var activeModelID: String
    @Published private(set) var operationModelID: String?
    @Published private(set) var error: String?
    @Published private(set) var isChecking = true
    var isBusy: Bool { isChecking || operationModelID != nil }

    /// The app must stop/deny active dictation and await runtime unload here. The
    /// argument is the newly selected ID, or nil when deleting the selected model.
    /// An absent coordinator blocks selection/deletion of the selected model.
    var beforeModelChange: (@MainActor (String?) async throws -> Void)?
    /// Called for operation start/end and selection changes (not every progress tick).
    var onModelOperationChange: (@MainActor () -> Void)?

    let rootDirectory: URL
    private let store: ModelStore
    private let defaults: UserDefaults
    private let diagnostics: ModelOperationDiagnostics.Recorder
    private var operation: Task<Void, Never>?
    private var operationToken: UUID?
    private var installedIDs: Set<String> = []
    private var lastSources: [String: ModelDownloadSource] = [:]

    init(rootDirectory: URL = ModelManager.defaultRootDirectory, defaults: UserDefaults = .standard,
         diagnostics: @escaping ModelOperationDiagnostics.Recorder = ModelOperationDiagnostics.record) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.defaults = defaults
        self.diagnostics = diagnostics
        store = ModelStore(root: rootDirectory, diagnostics: diagnostics)
        entries = ModelCatalog.models.map { ModelEntry(model: $0) }
        let saved = defaults.string(forKey: "managedModelID")
        activeModelID = saved.flatMap { ModelCatalog.model(id: $0)?.id } ?? ModelCatalog.defaultModelID
        // Do not adopt development folders or trigger any download during initialization.
        Task { [weak self] in await self?.checkExistingFiles() }
    }

    private func checkExistingFiles() async {
        for model in ModelCatalog.models {
            let operationID = UUID()
            record(model.id, operationID: operationID, action: "inspect", stage: "started")
            do {
                let result = try await store.inspect(model)
                if result.installed { installedIDs.insert(model.id) }
                if let source = result.source { lastSources[model.id] = source }
                update(model.id) {
                    $0.phase = result.installed ? .installed : (result.source != nil || result.bytes > 0 ? .paused : .notInstalled)
                    $0.downloadedBytes = result.bytes
                    $0.source = result.source
                }
                record(model.id, operationID: operationID, action: "inspect", stage: "completed")
            } catch {
                update(model.id) { $0.phase = .failed; $0.error = error.localizedDescription }
                record(model.id, operationID: operationID, action: "inspect", stage: "failed", error: error)
            }
        }
        isChecking = false
        onModelOperationChange?()
    }

    func entry(modelID: String) -> ModelEntry? { entries.first { $0.id == modelID } }

    /// Returns only a directory fully verified during this launch/install. No fallback
    /// to another model, manual folder, or Hugging Face's user cache is attempted.
    func installedDirectory(_ id: String) -> URL? {
        guard installedIDs.contains(id), let model = ModelCatalog.model(id: id) else { return nil }
        let directory = rootDirectory.appendingPathComponent(model.id, isDirectory: true)
        do {
            try ModelStore.checkPath(directory)
            for file in model.manifest.files {
                let path = directory.appendingPathComponent(file.name)
                try ModelStore.checkPath(path)
                let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
                guard attrs[.type] as? FileAttributeType == .typeRegular,
                      (attrs[.size] as? NSNumber)?.int64Value == file.bytes else { return nil }
            }
            return directory
        } catch { return nil }
    }

    func install(modelID: String, source: ModelDownloadSource) {
        let token = UUID()
        record(modelID, operationID: token, action: "install", stage: "requested")
        guard !isBusy else {
            error = ModelManagementError.busy.localizedDescription
            record(modelID, operationID: token, action: "install", stage: "rejected", error: ModelManagementError.busy)
            return
        }
        guard let model = ModelCatalog.model(id: modelID) else {
            error = ModelManagementError.unknownModel.localizedDescription
            record(modelID, operationID: token, action: "install", stage: "rejected", error: ModelManagementError.unknownModel)
            return
        }
        guard !installedIDs.contains(modelID) else {
            record(modelID, operationID: token, action: "install", stage: "rejected")
            return
        }
        do { for file in model.manifest.files { _ = try source.url(for: file, manifest: model.manifest) } }
        catch {
            self.error = error.localizedDescription
            record(modelID, operationID: token, action: "install", stage: "rejected", error: error)
            return
        }
        error = nil
        operationToken = token
        operationModelID = modelID
        lastSources[modelID] = source
        update(modelID) { $0.phase = .verifying; $0.error = nil; $0.source = source }
        record(modelID, operationID: token, action: "install", stage: "started")
        onModelOperationChange?()
        operation = Task { [weak self, store] in
            guard let self else { return }
            do {
                try await store.install(model, source: source) { [weak self] bytes, name, verifying in
                    Task { @MainActor [weak self] in
                        guard let self, self.operationToken == token,
                              self.operationModelID == modelID else { return }
                        self.update(modelID) {
                            $0.downloadedBytes = bytes
                            $0.currentFile = name
                            $0.phase = verifying ? .verifying : .downloading
                        }
                    }
                }
                self.operationToken = nil
                self.installedIDs.insert(modelID)
                self.update(modelID) { $0.phase = .installed; $0.downloadedBytes = model.totalBytes; $0.currentFile = nil; $0.error = nil }
                self.record(modelID, operationID: token, action: "install", stage: "completed")
            } catch {
                self.operationToken = nil
                let retainedBytes = (try? await store.stagedBytes(model)) ?? 0
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.update(modelID) {
                        $0.phase = .paused; $0.currentFile = nil; $0.error = nil; $0.downloadedBytes = retainedBytes
                    }
                    self.record(modelID, operationID: token, action: "install", stage: "cancelled", error: error)
                } else {
                    self.error = error.localizedDescription
                    self.update(modelID) {
                        $0.phase = .failed; $0.currentFile = nil; $0.error = error.localizedDescription; $0.downloadedBytes = retainedBytes
                    }
                    self.record(modelID, operationID: token, action: "install", stage: "failed", error: error)
                }
            }
            self.operation = nil
            self.operationModelID = nil
            self.onModelOperationChange?()
        }
    }

    /// Retain staged verified files AND the current .part. The next attempt checks
    /// Content-Range and final SHA-256; servers ignoring Range restart only that file.
    func cancel() {
        let operationID = operationToken ?? UUID()
        record(operationModelID, operationID: operationID, action: "cancel", stage: "requested")
        operation?.cancel()
        record(operationModelID, operationID: operationID, action: "cancel", stage: operation != nil ? "completed" : "rejected")
    }

    func retry(modelID: String) {
        install(modelID: modelID, source: lastSources[modelID] ?? .huggingFace)
    }

    func select(modelID: String) async throws {
        let operationID = UUID()
        record(modelID, operationID: operationID, action: "select", stage: "requested")
        let beforeModelChange: @MainActor (String?) async throws -> Void
        do {
            guard !isBusy else { throw ModelManagementError.busy }
            guard ModelCatalog.model(id: modelID) != nil else { throw ModelManagementError.unknownModel }
            guard installedDirectory(modelID) != nil else { throw ModelManagementError.notInstalled }
            guard let coordinator = self.beforeModelChange else { throw ModelManagementError.coordinationRequired }
            beforeModelChange = coordinator
        } catch {
            record(modelID, operationID: operationID, action: "select", stage: "rejected", error: error)
            throw error
        }
        operationModelID = modelID
        error = nil
        record(modelID, operationID: operationID, action: "select", stage: "started")
        onModelOperationChange?()
        defer { operationModelID = nil; onModelOperationChange?() }
        do {
            record(modelID, operationID: operationID, action: "select", stage: "coordination")
            try await beforeModelChange(modelID)
            record(modelID, operationID: operationID, action: "select", stage: "coordinated")
            activeModelID = modelID
            defaults.set(modelID, forKey: "managedModelID")
            record(modelID, operationID: operationID, action: "select", stage: "completed")
        } catch {
            self.error = error.localizedDescription
            record(modelID, operationID: operationID, action: "select", stage: "failed", error: error)
            throw error
        }
    }

    /// Explicit deletion only. The runtime coordinator is awaited BEFORE removing a
    /// selected model. Deleting it selects the default ID, never another installed model.
    func delete(modelID: String, operationID: UUID = UUID()) async throws {
        record(modelID, operationID: operationID, action: "delete", stage: "requested")
        let model: CatalogModel
        do {
            guard !isBusy else { throw ModelManagementError.busy }
            guard let found = ModelCatalog.model(id: modelID) else { throw ModelManagementError.unknownModel }
            model = found
            if modelID == activeModelID && beforeModelChange == nil { throw ModelManagementError.coordinationRequired }
        } catch {
            record(modelID, operationID: operationID, action: "delete", stage: "rejected", error: error)
            throw error
        }
        operationModelID = modelID
        error = nil
        let oldPhase = entry(modelID: modelID)?.phase ?? .notInstalled
        update(modelID) { $0.phase = .deleting; $0.error = nil }
        record(modelID, operationID: operationID, action: "delete", stage: "started")
        onModelOperationChange?()
        defer { operationModelID = nil; onModelOperationChange?() }
        do {
            // Always notify the coordinator if present: a manual override can point
            // at a managed folder other than the currently selected managed ID.
            if let beforeModelChange {
                record(modelID, operationID: operationID, action: "delete", stage: "coordination")
                try await beforeModelChange(nil)
                record(modelID, operationID: operationID, action: "delete", stage: "coordinated")
            }
            record(modelID, operationID: operationID, action: "delete", stage: "filesystem")
            try await store.delete(model, operationID: operationID)
            installedIDs.remove(modelID)
            lastSources.removeValue(forKey: modelID)
            if activeModelID == modelID {
                activeModelID = ModelCatalog.defaultModelID
                defaults.set(activeModelID, forKey: "managedModelID")
            }
            update(modelID) { $0.phase = .notInstalled; $0.downloadedBytes = 0; $0.currentFile = nil; $0.source = nil }
            record(modelID, operationID: operationID, action: "delete", stage: "completed")
        } catch {
            self.error = error.localizedDescription
            update(modelID) { $0.phase = oldPhase; $0.error = error.localizedDescription }
            record(modelID, operationID: operationID, action: "delete", stage: "failed", error: error)
            throw error
        }
    }

    func clearError() { error = nil }

    private func record(_ modelID: String?, operationID: UUID, action: String, stage: String,
                        error: (any Error)? = nil) {
        let entry = modelID.flatMap { self.entry(modelID: $0) }
        diagnostics(ModelOperationDiagnostics.metadata(
            modelID: modelID, operationID: operationID, action: action, stage: stage,
            phase: entry?.phase.rawValue, downloadedBytes: entry?.downloadedBytes,
            totalBytes: entry?.totalBytes, error: error
        ))
    }

    private func update(_ id: String, _ mutate: (inout ModelEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
    }
}
