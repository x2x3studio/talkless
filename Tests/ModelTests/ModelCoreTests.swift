import Foundation
import CryptoKit

private enum TestFailure: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw TestFailure.assertion(message) }
}
private func expectThrows(_ message: String, _ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw TestFailure.assertion(message)
}
private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

private final class HTTPFixture: URLProtocol, @unchecked Sendable {
    struct Plan: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var failAfterBody = false
        var delayFinish = false
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var plans: [Plan] = []
        var requests: [URLRequest] = []
        func reset(_ plans: [Plan]) { lock.withLock { self.plans = plans; requests = [] } }
        func next(_ request: URLRequest) -> Plan {
            lock.withLock {
                requests.append(request)
                return plans.isEmpty ? Plan(status: 500) : plans.removeFirst()
            }
        }
        var allRequests: [URLRequest] { lock.withLock { requests } }
    }
    static let state = State()
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let plan = Self.state.next(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: plan.status,
                                       httpVersion: "HTTP/1.1", headerFields: plan.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.body)
        if plan.delayFinish {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                guard !lock.withLock({ stopped }) else { return }
                client?.urlProtocolDidFinishLoading(self)
            }
        } else if plan.failAfterBody {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                guard !lock.withLock({ stopped }) else { return }
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        } else { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

private func downloader() -> ModelFileDownloader {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [HTTPFixture.self]
    return ModelFileDownloader(configuration: config)
}

@main
struct ModelCoreTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("talkless-model-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try catalogueTests()
        try await downloaderTests(root)
        try await storeTests(root)
        try await managerTests(root)
        print("PASS: catalogue pins, URL/path safety, streaming HTTP, resume/restart/cancel, SHA verification, staging recovery, atomic install, managed deletion, selection defaults")
    }

    static func catalogueTests() throws {
        for model in ModelCatalog.models {
            try model.manifest.validate()
            try expect(model.manifest.files.contains { $0.name == "config.json" }, "Missing config")
            try expect(model.manifest.files.contains { $0.name == "tokenizer_config.json" }, "Missing tokenizer")
            try expect(model.manifest.files.contains { $0.name == "model.safetensors.index.json" }, "Missing weight index")
            let file = model.manifest.files.last!
            let url = try ModelDownloadSource.huggingFace.url(for: file, manifest: model.manifest)
            try expect(url.path.contains("/resolve/\(model.manifest.revision)/"), "Unpinned URL")
            try expect(model.totalBytes == model.manifest.files.reduce(0) { $0 + $1.bytes }, "Wrong total")
        }
        try expect(ModelCatalog.models[0].manifest.files.last?.bytes == 708236945, "Default weight size mismatch")
        try expect(ModelCatalog.models.count == 1, "Only the 0.6B local model should be offered")
        try expect(ModelCatalog.models[0].manifest.files.last?.sha256 == "70c7e67e588062adce4f10796e47ad42ead51c6671eda61a0987eae38ca95ddf", "Receipt mismatch")
        let manifest = ModelCatalog.models[0].manifest
        for value in ["http://example.com", "file:///tmp/model", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com/#fragment", "https://example.com/a/../b"] {
            try expectThrows("Accepted insecure source \(value)") {
                _ = try ModelDownloadSource.custom(URL(string: value)!).url(for: manifest.files[0], manifest: manifest)
            }
        }
        for name in ["../outside", "/tmp/outside", "a/b", "a\\b", "%2e%2e", ".", "..", "hidden\nfile", "model-manifest.json"] {
            let bad = ModelManifest(modelID: "test", repository: "test/test", revision: manifest.revision,
                                    files: [ModelFile(name: name, bytes: 1, sha256: String(repeating: "a", count: 64))])
            try expectThrows("Accepted path traversal \(name)") { try bad.validate() }
        }
        let repeated = ModelManifest(modelID: "test", repository: "test/test", revision: manifest.revision,
                                     files: [manifest.files[0], manifest.files[0]])
        try expectThrows("Accepted duplicate filenames") { try repeated.validate() }
        try expect(ModelFileDownloader.validContentRange("bytes 3-9/10", offset: 3, total: 10), "Valid Range rejected")
        for range in ["bytes 0-9/10", "bytes 3-8/10", "bytes 3-9/*", "bytes 3-9/11", "bytes */10", "items 3-9/10"] {
            try expect(!ModelFileDownloader.validContentRange(range, offset: 3, total: 10), "Invalid Range accepted")
        }
    }

    static func downloaderTests(_ root: URL) async throws {
        let file = root.appendingPathComponent("download.part")
        let data = Data("abcdefghij".utf8)
        let url = URL(string: "https://fixture.invalid/model")!
        HTTPFixture.state.reset([.init(headers: ["Content-Length": "10"], body: data)])
        try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }
        try expect(try Data(contentsOf: file) == data, "Full download mismatch")
        try Data(data.prefix(3)).write(to: file)
        HTTPFixture.state.reset([.init(status: 206, headers: ["Content-Length": "7", "Content-Range": "bytes 3-9/10"], body: Data(data.dropFirst(3)))])
        try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }
        try expect(HTTPFixture.state.allRequests[0].value(forHTTPHeaderField: "Range") == "bytes=3-", "Resume did not send Range")
        try expect(try Data(contentsOf: file) == data, "Resumed bytes mismatch")
        try Data(data.prefix(3)).write(to: file)
        HTTPFixture.state.reset([.init(headers: ["Content-Length": "10"], body: data)])
        try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }
        try expect(try Data(contentsOf: file) == data, "Ignored Range appended instead of restarting")
        try Data(data.prefix(3)).write(to: file)
        HTTPFixture.state.reset([.init(status: 206, headers: ["Content-Range": "bytes 0-9/10"], body: data)])
        do {
            try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }
            throw TestFailure.assertion("Invalid Range succeeded")
        } catch is TestFailure { throw TestFailure.assertion("Invalid Range succeeded") } catch {}
        try expect(try Data(contentsOf: file) == Data(data.prefix(3)), "Invalid Range changed partial")
        HTTPFixture.state.reset([.init(status: 206, headers: ["Content-Length": "7", "Content-Range": "bytes 3-9/10"], failAfterBody: true)])
        do { try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }; throw TestFailure.assertion("Interrupted download succeeded") }
        catch is TestFailure { throw TestFailure.assertion("Interrupted download succeeded") } catch {}
        try expect(try Data(contentsOf: file) == Data(data.prefix(3)), "Network failure discarded partial")
        HTTPFixture.state.reset([.init(status: 206, headers: ["Content-Length": "7", "Content-Range": "bytes 3-9/10"], delayFinish: true)])
        let worker = downloader()
        let task = Task { try await worker.download(url: url, partial: file, expectedBytes: 10) { count in if count == 3 { worker.cancel() } } }
        do { try await task.value; throw TestFailure.assertion("Cancelled download succeeded") }
        catch is TestFailure { throw TestFailure.assertion("Cancelled download succeeded") } catch {}
        try expect(try Data(contentsOf: file) == Data(data.prefix(3)), "Cancellation discarded partial")
        try FileManager.default.removeItem(at: file)
        HTTPFixture.state.reset([.init(body: Data(repeating: 0, count: 11))])
        do { try await downloader().download(url: url, partial: file, expectedBytes: 10) { _ in }; throw TestFailure.assertion("Oversized download succeeded") }
        catch is TestFailure { throw TestFailure.assertion("Oversized download succeeded") } catch {}
        try expect((try Data(contentsOf: file)).count <= 10, "Oversized body written to disk")
    }

    static func storeTests(_ root: URL) async throws {
        let folder = root.appendingPathComponent("managed")
        let bytes = Data("verified model".utf8)
        let file = ModelFile(name: "model.safetensors", bytes: Int64(bytes.count), sha256: digest(bytes))
        let manifest = ModelManifest(modelID: "test-model", repository: "test/model", revision: String(repeating: "a", count: 40), files: [file])
        let model = CatalogModel(id: manifest.modelID, name: "Test", summary: "Test", isRecommended: false, manifest: manifest)
        let store = ModelStore(root: folder, makeDownloader: { downloader() })
        let initial = try await store.inspect(model)
        try expect(!initial.installed, "Absent model installed")
        HTTPFixture.state.reset([.init(body: Data(repeating: 0, count: bytes.count))])
        do { try await store.install(model, source: .huggingFace) { _, _, _ in }; throw TestFailure.assertion("Wrong SHA installed") }
        catch is TestFailure { throw TestFailure.assertion("Wrong SHA installed") } catch {}
        let destination = folder.appendingPathComponent(model.id)
        let stage = folder.appendingPathComponent(".\(model.id).staging")
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Failed download published directory")
        try expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent(file.name + ".part").path), "Corrupt partial not removed")
        try Data(bytes.prefix(4)).write(to: stage.appendingPathComponent(file.name + ".part"))
        let recovered = try await ModelStore(root: folder).inspect(model)
        try expect(!recovered.installed && recovered.bytes == 4 && recovered.source == .huggingFace, "Restart did not recover partial/source")
        HTTPFixture.state.reset([.init(status: 206, headers: ["Content-Range": "bytes 4-\(bytes.count - 1)/\(bytes.count)"], body: Data(bytes.dropFirst(4)))])
        try await store.install(model, source: .hfMirror) { _, _, _ in }
        try expect(HTTPFixture.state.allRequests[0].url?.host == "hf-mirror.com", "Changed source not used")
        let installed = try await store.inspect(model)
        try expect(installed.installed, "Verified install not detected")
        try expect(!FileManager.default.fileExists(atPath: stage.path), "Atomic publication left staging")
        let tokenizerCache = destination.appendingPathComponent("tokenizer.json")
        try Data("{\"version\":\"1.0\",\"model\":{}}".utf8).write(to: tokenizerCache)
        let afterRuntime = try await store.inspect(model)
        try expect(afterRuntime.installed, "Runtime-generated tokenizer cache rejected")
        for invalidCache in [Data("[]".utf8), Data("not JSON".utf8), Data(repeating: 32, count: 32 * 1024 * 1024 + 1)] {
            try invalidCache.write(to: tokenizerCache)
            do { _ = try await store.inspect(model); throw TestFailure.assertion("Invalid tokenizer cache accepted") }
            catch is TestFailure { throw TestFailure.assertion("Invalid tokenizer cache accepted") } catch {}
        }
        let cacheTarget = root.appendingPathComponent("cache-target.json")
        try Data("{}".utf8).write(to: cacheTarget)
        try FileManager.default.removeItem(at: tokenizerCache)
        try FileManager.default.createSymbolicLink(at: tokenizerCache, withDestinationURL: cacheTarget)
        do { _ = try await store.inspect(model); throw TestFailure.assertion("Symlink tokenizer cache accepted") }
        catch is TestFailure { throw TestFailure.assertion("Symlink tokenizer cache accepted") } catch {}
        do { try await store.delete(model); throw TestFailure.assertion("Symlink tokenizer cache deletion accepted") }
        catch is TestFailure { throw TestFailure.assertion("Symlink tokenizer cache deletion accepted") } catch {}
        try expect(FileManager.default.fileExists(atPath: cacheTarget.path), "Tokenizer cache symlink target deleted")
        try FileManager.default.removeItem(at: tokenizerCache)
        try Data("{}".utf8).write(to: tokenizerCache)
        let outside = root.appendingPathComponent("outside.txt")
        try bytes.write(to: outside)
        let weight = destination.appendingPathComponent(file.name)
        try FileManager.default.removeItem(at: weight)
        try FileManager.default.createSymbolicLink(at: weight, withDestinationURL: outside)
        do { try await store.delete(model); throw TestFailure.assertion("Symlink deletion accepted") }
        catch is TestFailure { throw TestFailure.assertion("Symlink deletion accepted") } catch {}
        try expect(try Data(contentsOf: outside) == bytes, "Symlink target changed")
        try FileManager.default.removeItem(at: weight)
        try bytes.write(to: weight)
        try await store.delete(model)
        try expect(!FileManager.default.fileExists(atPath: destination.path), "Managed delete failed")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try bytes.write(to: destination.appendingPathComponent("user-file"))
        do { try await store.delete(model); throw TestFailure.assertion("Unmanaged deletion accepted") }
        catch is TestFailure { throw TestFailure.assertion("Unmanaged deletion accepted") } catch {}
        try expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("user-file").path), "Unmanaged content deleted")
        let linkedRoot = root.appendingPathComponent("linked-models")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: folder)
        do { _ = try await ModelStore(root: linkedRoot).inspect(model); throw TestFailure.assertion("Symlink root accepted") }
        catch is TestFailure { throw TestFailure.assertion("Symlink root accepted") } catch {}
    }

    @MainActor static func managerTests(_ root: URL) async throws {
        let suite = "TalklessModelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("../../outside", forKey: "managedModelID")
        let manager = ModelManager(rootDirectory: root.appendingPathComponent("manager"), defaults: defaults)
        while manager.isChecking { try await Task.sleep(for: .milliseconds(10)) }
        try expect(manager.activeModelID == ModelCatalog.defaultModelID, "Unknown saved selection accepted")
        try expect(manager.entries.allSatisfy { $0.phase == .notInstalled }, "Initialization downloaded or adopted a model")
        try expect(manager.installedDirectory(ModelCatalog.defaultModelID) == nil, "Uninstalled model returned a directory")
        do { try await manager.select(modelID: ModelCatalog.defaultModelID); throw TestFailure.assertion("Uninstalled selection accepted") }
        catch is TestFailure { throw TestFailure.assertion("Uninstalled selection accepted") } catch {}
        manager.install(modelID: "../outside", source: .huggingFace)
        try expect(!manager.isBusy && manager.error != nil, "Unknown install accepted")
        manager.beforeModelChange = { _ in }
        try await manager.delete(modelID: ModelCatalog.defaultModelID)
        try expect(manager.activeModelID == ModelCatalog.defaultModelID, "Default delete selected unexpected model")
    }
}
