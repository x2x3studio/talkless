import Foundation
import CryptoKit

/// One file at a time. URLSession delivers bounded chunks directly to disk; weights
/// are never collected in a Data value. A .part is reusable only with its pinned manifest.
final class ModelFileDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false
    // The remaining state is confined to the session's serial delegate queue.
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var handle: FileHandle?
    private var expected: Int64 = 0
    private var received: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var failure: (any Error)?
    private var lastProgress = Date.distantPast
    private var progress: (@Sendable (Int64) -> Void)?
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration
        super.init()
    }

    func download(url: URL, partial: URL, expectedBytes: Int64,
                  progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                do {
                    guard ModelDownloadSource.isSecureURL(url) else { throw ModelManagementError.invalidSource }
                    if !FileManager.default.fileExists(atPath: partial.path) {
                        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                            throw ModelManagementError.download("Could not create the partial file.")
                        }
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: partial.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber,
                          size.int64Value <= expectedBytes else { throw ModelManagementError.unsafePath }
                    handle = try FileHandle(forWritingTo: partial)
                    requestedOffset = size.int64Value
                    received = requestedOffset
                    expected = expectedBytes
                    self.progress = progress
                    self.continuation = continuation
                    try handle?.seekToEnd()
                    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                    if requestedOffset > 0 { request.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
                    let configuration = self.configuration
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 24 * 60 * 60
                    configuration.httpMaximumConnectionsPerHost = 1
                    configuration.urlCache = nil
                    configuration.httpCookieStorage = nil
                    configuration.urlCredentialStorage = nil
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    queue.qualityOfService = .utility
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: request)
                    let shouldCancel = lock.withLock { self.task = task; return cancelled }
                    if shouldCancel { task.cancel() }
                    task.resume()
                } catch {
                    try? handle?.close()
                    handle = nil
                    self.continuation = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let current = lock.withLock { cancelled = true; return task }
        current?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, ModelDownloadSource.isSecureURL(url) else {
            failure = ModelManagementError.invalidSource
            completionHandler(nil)
            return
        }
        // Signed HTTPS CDN redirects are expected. Never carry credentials to another host.
        var redirected = request
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if requestedOffset > 0 { redirected.setValue("bytes=\(requestedOffset)-", forHTTPHeaderField: "Range") }
        completionHandler(redirected)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let http = response as? HTTPURLResponse,
                  let url = http.url, ModelDownloadSource.isSecureURL(url) else {
                throw ModelManagementError.download("The server did not return an HTTPS response.")
            }
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
            guard encoding == nil || encoding == "identity" else {
                throw ModelManagementError.download("The server changed the file encoding.")
            }
            if http.statusCode == 206 {
                guard Self.validContentRange(http.value(forHTTPHeaderField: "Content-Range"),
                                             offset: requestedOffset, total: expected) else {
                    throw ModelManagementError.download("The server returned an invalid resume range.")
                }
            } else if http.statusCode == 200 {
                // A server may ignore Range. Restart this file, rather than append and corrupt it.
                try handle?.truncate(atOffset: 0)
                try handle?.seek(toOffset: 0)
                received = 0
            } else {
                throw ModelManagementError.download("HTTP \(http.statusCode). Check the source or try again.")
            }
            let remaining = expected - received
            if response.expectedContentLength >= 0 && response.expectedContentLength != remaining {
                throw ModelManagementError.download("The server returned an unexpected file size.")
            }
            progress?(received)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    static func validContentRange(_ value: String?, offset: Int64, total: Int64) -> Bool {
        guard let value, value.hasPrefix("bytes ") else { return false }
        let pieces = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, Int64(pieces[1]) == total else { return false }
        let bounds = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
        return bounds.count == 2 && Int64(bounds[0]) == offset && Int64(bounds[1]) == total - 1 && offset < total
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            guard Int64(data.count) <= expected - received else {
                throw ModelManagementError.download("The server sent more data than the pinned file size.")
            }
            try handle?.write(contentsOf: data)
            received += Int64(data.count)
            if Date().timeIntervalSince(lastProgress) >= 0.1 || received == expected {
                lastProgress = Date()
                progress?(received)
            }
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        do { try handle?.synchronize(); try handle?.close() } catch { if failure == nil { failure = error } }
        handle = nil
        let completion = continuation
        continuation = nil
        let wasCancelled = lock.withLock { self.task = nil; return cancelled }
        progress?(received)
        session.finishTasksAndInvalidate()
        self.session = nil
        if let failure { completion?.resume(throwing: failure) }
        else if wasCancelled { completion?.resume(throwing: CancellationError()) }
        else if let error { completion?.resume(throwing: error) }
        else if received != expected { completion?.resume(throwing: ModelManagementError.download("The file ended before it was complete.")) }
        else { completion?.resume() }
    }
}

/// Disk work and streaming SHA-256 run off the main actor. No paths from network
/// responses or persisted manifests are ever used to choose a destination.
actor ModelStore {
    let root: URL
    private let fm = FileManager.default
    private static let manifestName = "model-manifest.json"
    private static let sourceName = "download-source.json"
    private let makeDownloader: @Sendable () -> ModelFileDownloader

    init(root: URL, makeDownloader: @escaping @Sendable () -> ModelFileDownloader = { ModelFileDownloader() }) {
        self.root = root.standardizedFileURL
        self.makeDownloader = makeDownloader
    }

    func directory(_ model: CatalogModel) -> URL { root.appendingPathComponent(model.id, isDirectory: true) }
    private func staging(_ model: CatalogModel) -> URL { root.appendingPathComponent(".\(model.id).staging", isDirectory: true) }

    /// Reject symlinks at every existing component, including the root's ancestors.
    static func checkPath(_ url: URL) throws {
        var component = url.standardizedFileURL
        while component.path != "/" {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: component.path)
                if attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    // Foundation canonicalizes /private/var back to /var. These two
                    // system-owned macOS aliases are not user-controlled model links.
                    let systemAlias = ["/var": "private/var", "/tmp": "private/tmp"][component.path]
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: component.path)
                    guard let systemAlias, target == systemAlias || target == "/" + systemAlias else {
                        throw ModelManagementError.unsafePath
                    }
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // The leaf may not exist yet; still check its parents.
            }
            component.deleteLastPathComponent()
        }
    }

    private func prepareRoot(_ model: CatalogModel) throws {
        try model.manifest.validate()
        guard model.id == model.manifest.modelID else { throw ModelManagementError.invalidManifest }
        try Self.checkPath(root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.checkPath(root)
    }

    private func readManifest(in folder: URL, model: CatalogModel) throws {
        try Self.checkPath(folder)
        let receipt = folder.appendingPathComponent(Self.manifestName)
        try Self.checkPath(receipt)
        let attributes = try fm.attributesOfItem(atPath: receipt.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value ?? Int64.max < 128_000,
              let saved = try? JSONDecoder().decode(ModelManifest.self, from: Data(contentsOf: receipt)),
              saved == model.manifest else { throw ModelManagementError.unmanagedDirectory }
    }

    private func checkContents(_ folder: URL, model: CatalogModel, partials: Bool) throws {
        try readManifest(in: folder, model: model)
        var allowed = Set(model.manifest.files.map(\.name))
        allowed.formUnion([Self.manifestName, Self.sourceName])
        if partials { allowed.formUnion(model.manifest.files.map { $0.name + ".part" }) }
        for child in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            try Self.checkPath(child)
            let attrs = try fm.attributesOfItem(atPath: child.path)
            guard attrs[.type] as? FileAttributeType == .typeRegular else {
                throw ModelManagementError.unsafePath
            }
            if child.lastPathComponent == "tokenizer.json", !allowed.contains("tokenizer.json") {
                // The native tokenizer synthesizes this cache from the pinned vocab,
                // merges and tokenizer config on first load. It is not a downloaded
                // manifest file and must never relax validation of those source files.
                guard let size = attrs[.size] as? NSNumber, size.int64Value > 0,
                      size.int64Value <= 32 * 1024 * 1024,
                      (try? JSONSerialization.jsonObject(with: Data(contentsOf: child))) is [String: Any] else {
                    throw ModelManagementError.unsafePath
                }
            } else if !allowed.contains(child.lastPathComponent) {
                throw ModelManagementError.unsafePath
            }
        }
    }

    static func verify(_ url: URL, file: ModelFile) throws -> Bool {
        try checkPath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else { throw ModelManagementError.unsafePath }
        guard (attrs[.size] as? NSNumber)?.int64Value == file.bytes else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined() == file.sha256
    }

    func inspect(_ model: CatalogModel) throws -> (installed: Bool, bytes: Int64, source: ModelDownloadSource?) {
        try prepareRoot(model)
        let installed = directory(model)
        if fm.fileExists(atPath: installed.path) {
            try checkContents(installed, model: model, partials: false)
            for file in model.manifest.files {
                guard try Self.verify(installed.appendingPathComponent(file.name), file: file) else {
                    throw ModelManagementError.corruptFile(file.name)
                }
            }
            return (true, model.totalBytes, nil)
        }
        let stage = staging(model)
        guard fm.fileExists(atPath: stage.path) else { return (false, 0, nil) }
        try checkContents(stage, model: model, partials: true)
        var bytes: Int64 = 0
        for file in model.manifest.files {
            let complete = stage.appendingPathComponent(file.name)
            if try Self.verify(complete, file: file) { bytes += file.bytes }
            else {
                let part = stage.appendingPathComponent(file.name + ".part")
                if let attrs = try? fm.attributesOfItem(atPath: part.path), let size = attrs[.size] as? NSNumber {
                    bytes += min(file.bytes, max(0, size.int64Value))
                }
            }
        }
        let sourceURL = stage.appendingPathComponent(Self.sourceName)
        let sourceSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let source = sourceSize > 0 && sourceSize < 16_000 ?
            (try? JSONDecoder().decode(ModelDownloadSource.self, from: Data(contentsOf: sourceURL))) : nil
        return (false, bytes, source)
    }

    /// Bytes actually retained on disk, not a claim of successful verification.
    func stagedBytes(_ model: CatalogModel) throws -> Int64 {
        let stage = staging(model)
        guard fm.fileExists(atPath: stage.path) else { return 0 }
        try checkContents(stage, model: model, partials: true)
        return model.manifest.files.reduce(0) { total, file in
            let candidates = [file.name, file.name + ".part"].map { name -> Int64 in
                let path = stage.appendingPathComponent(name)
                let attrs = try? fm.attributesOfItem(atPath: path.path)
                return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            }
            return total + min(file.bytes, max(0, candidates.max() ?? 0))
        }
    }

    func install(_ model: CatalogModel, source: ModelDownloadSource,
                 progress: @escaping @Sendable (Int64, String, Bool) -> Void) async throws {
        try prepareRoot(model)
        for file in model.manifest.files { _ = try source.url(for: file, manifest: model.manifest) }
        let destination = directory(model)
        try Self.checkPath(destination)
        guard !fm.fileExists(atPath: destination.path) else { throw ModelManagementError.unmanagedDirectory }
        let stage = staging(model)
        try Self.checkPath(stage)
        if fm.fileExists(atPath: stage.path) { try checkContents(stage, model: model, partials: true) }
        else {
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            try JSONEncoder().encode(model.manifest).write(to: stage.appendingPathComponent(Self.manifestName), options: .atomic)
        }
        try JSONEncoder().encode(source).write(to: stage.appendingPathComponent(Self.sourceName), options: .atomic)
        var completed: Int64 = 0
        for file in model.manifest.files {
            try Task.checkCancellation()
            try checkContents(stage, model: model, partials: true)
            let final = stage.appendingPathComponent(file.name)
            let partial = stage.appendingPathComponent(file.name + ".part")
            progress(completed, file.name, true)
            if try Self.verify(final, file: file) { completed += file.bytes; continue }
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            // An interrupted process may leave a fully received file before its rename.
            if try Self.verify(partial, file: file) {
                try fm.moveItem(at: partial, to: final)
                completed += file.bytes
                continue
            }
            if let attrs = try? fm.attributesOfItem(atPath: partial.path),
               let size = attrs[.size] as? NSNumber, size.int64Value >= file.bytes {
                try fm.removeItem(at: partial)
            }
            let prior = completed
            progress(prior, file.name, false)
            let downloader = makeDownloader()
            try await downloader.download(url: source.url(for: file, manifest: model.manifest), partial: partial,
                                          expectedBytes: file.bytes) { count in progress(prior + count, file.name, false) }
            progress(prior + file.bytes, file.name, true)
            guard try Self.verify(partial, file: file) else {
                try Self.checkPath(partial)
                try fm.removeItem(at: partial)
                throw ModelManagementError.corruptFile(file.name)
            }
            try fm.moveItem(at: partial, to: final)
            completed += file.bytes
        }
        try Task.checkCancellation()
        // Recheck the entire manifest immediately before activation, including files reused from staging.
        for file in model.manifest.files {
            progress(completed, file.name, true)
            guard try Self.verify(stage.appendingPathComponent(file.name), file: file) else {
                throw ModelManagementError.corruptFile(file.name)
            }
        }
        try Task.checkCancellation()
        try checkContents(stage, model: model, partials: true)
        // Remove only known leftover partials; an atomic same-volume directory rename publishes the model.
        for file in model.manifest.files {
            let partial = stage.appendingPathComponent(file.name + ".part")
            if fm.fileExists(atPath: partial.path) { try fm.removeItem(at: partial) }
        }
        try Self.checkPath(destination)
        try fm.moveItem(at: stage, to: destination)
    }

    func delete(_ model: CatalogModel) throws {
        try prepareRoot(model)
        // Validate BOTH trees before removing either one. Never follow a symlink or remove unowned content.
        let folders = [directory(model), staging(model)]
        for folder in folders {
            try Self.checkPath(folder)
            if fm.fileExists(atPath: folder.path) { try checkContents(folder, model: model, partials: true) }
        }
        for folder in folders where fm.fileExists(atPath: folder.path) {
            try Self.checkPath(folder)
            try fm.removeItem(at: folder)
        }
    }
}
