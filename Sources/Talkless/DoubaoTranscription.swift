import AVFoundation
import Foundation

/// Injectable transport: tests exercise the real session with a scripted server, without keys/audio/network.
protocol DoubaoSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close()
}

private final class DoubaoWebSocket: NSObject, DoubaoSocket, URLSessionTaskDelegate, @unchecked Sendable {
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    init(request: URLRequest) {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = DoubaoProtocol.maximumPayload + 1024
        task.resume()
    }
    func send(_ data: Data) async throws {
        do { try await task.send(.data(data)) }
        catch { throw connectionError(error) }
    }
    func receive() async throws -> Data {
        do {
            switch try await task.receive() {
            case .data(let data): return data
            default: throw DoubaoError.invalidResponse
            }
        } catch { throw connectionError(error) }
    }
    private func connectionError(_ error: Error) -> Error {
        if let status = (task.response as? HTTPURLResponse)?.statusCode, status != 101 {
            return DoubaoError.authentication
        }
        return error
    }
    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
    // Never forward the Speech API key through a redirect.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One WebSocket per dictation. Audio capture only copies PCM into a bounded mailbox;
/// JSON, compression, network I/O and waits never run on the audio thread or main actor.
final class DoubaoTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let state = DoubaoSessionState()
    private let socket: any DoubaoSocket
    private var worker: Task<Void, Never>?

    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { state.lock.withLock { state.onPartial } }
        set { state.lock.withLock { state.onPartial = newValue } }
    }

    init(config: DoubaoConfig, socket: (any DoubaoSocket)? = nil,
         timeout: TimeInterval = 15,
         onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }) throws {
        let request = try config.request()
        self.socket = socket ?? DoubaoWebSocket(request: request)
        let socket = self.socket, state = self.state
        worker = Task.detached(priority: .userInitiated) {
            do {
                let text = try await Self.run(socket: socket, state: state, timeout: timeout, inputLanguage: config.inputLanguage)
                state.resolve(.success(text))
            } catch {
                let safeError: Error
                if error is CancellationError || Task.isCancelled { safeError = CancellationError() }
                else if let error = error as? DoubaoError { safeError = error }
                else if let error = error as? URLError, error.code == .timedOut { safeError = DoubaoError.timeout }
                else { safeError = DoubaoError.connection }
                state.resolve(.failure(safeError))
                if !(safeError is CancellationError) {
                    await MainActor.run {
                        if !state.isCancelled { onError(safeError.localizedDescription) }
                    }
                }
            }
        }
    }

    /// Validate credentials/resource by sending only the configuration frame and waiting for
    /// a valid service acknowledgment. No microphone, audio packet or recognition accuracy test.
    static func validateConnection(config: DoubaoConfig, socket injected: (any DoubaoSocket)? = nil,
                                   timeout: TimeInterval = 10) async throws {
        let request = try config.request()
        let socket = injected ?? DoubaoWebSocket(request: request)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    defer { group.cancelAll(); socket.close() }
                    group.addTask {
                        try Task.checkCancellation()
                        try await socket.send(DoubaoProtocol.configuration(inputLanguage: config.inputLanguage))
                        _ = try DoubaoProtocol.response(await socket.receive())
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(timeout))
                        throw DoubaoError.timeout
                    }
                    _ = try await group.next()
                    try Task.checkCancellation()
                }
            } onCancel: { socket.close() }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let error = error as? DoubaoError { throw error }
            if let error = error as? URLError, error.code == .timedOut { throw DoubaoError.timeout }
            throw DoubaoError.connection
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard buffer.format.sampleRate == 16_000, buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32, let channel = buffer.floatChannelData?[0] else {
            state.abort(DoubaoError.invalidAudio); socket.close(); return
        }
        // Bound native callback work to copying; PCM16 packing happens in the sender.
        state.enqueue(Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
    }

    func finish(samples: [Float]) async throws -> String {
        // feed() owns the audio. The recorder's full copy must never be uploaded a second time.
        state.endAudio()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let value = try await state.value()
            try Task.checkCancellation()
            return value
        } onCancel: { self.cancel() }
    }

    func cancel() {
        state.cancel()
        socket.close()
        worker?.cancel()
    }
    deinit { state.cancel(); socket.close(); worker?.cancel() }

    private static func run(socket: any DoubaoSocket, state: DoubaoSessionState, timeout: TimeInterval,
                            inputLanguage: DoubaoInputLanguage) async throws -> String {
        try await withThrowingTaskGroup(of: String?.self) { group in
            defer { group.cancelAll(); socket.close(); state.closeMailbox() }
            group.addTask {
                try await socket.send(DoubaoProtocol.configuration(inputLanguage: inputLanguage))
                var pending = Data()
                for try await chunk in state.audio {
                    try Task.checkCancellation()
                    pending.append(chunk.withUnsafeBufferPointer { DoubaoProtocol.pcm16($0) })
                    while pending.count >= DoubaoProtocol.packetBytes {
                        let packet = Data(pending.prefix(DoubaoProtocol.packetBytes))
                        pending.removeFirst(DoubaoProtocol.packetBytes)
                        try await socket.send(DoubaoProtocol.audio(packet, final: false))
                    }
                    state.consumed(chunk.count)
                }
                try Task.checkCancellation()
                state.markFinalSent()
                try await socket.send(DoubaoProtocol.audio(pending, final: true))
                return nil
            }
            group.addTask {
                while true {
                    try Task.checkCancellation()
                    let response: DoubaoProtocol.Response
                    do {
                        response = try DoubaoProtocol.response(await socket.receive())
                    } catch DoubaoError.service(45_000_002) where state.finalWasSent {
                        // The service reports empty audio as an error, not an empty final result.
                        try Task.checkCancellation()
                        return ""
                    }
                    state.markConnected() // A successful send alone does not prove service acceptance.
                    if let text = response.text {
                        await MainActor.run {
                            let callback = state.lock.withLock { state.isCancelledLocked ? nil : state.onPartial }
                            callback?(text)
                        }
                    }
                    if response.isFinal {
                        guard state.finalWasSent else { throw DoubaoError.invalidResponse }
                        return response.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(100))
                    if state.hasTimedOut(limit: timeout) { throw DoubaoError.timeout }
                }
            }
            while let value = try await group.next() {
                if let value { return value }
            }
            throw DoubaoError.invalidResponse
        }
    }
}

private final class DoubaoSessionState: @unchecked Sendable {
    let lock = NSLock()
    var onPartial: (@MainActor @Sendable (String) -> Void)?
    private(set) var isCancelledLocked = false
    var isCancelled: Bool { lock.withLock { isCancelledLocked } }
    let audio: AsyncThrowingStream<[Float], Error>
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private var bufferedSamples = 0
    private var closed = false
    private var connected = false
    private var finalSent = false
    private var lastProgress = ProcessInfo.processInfo.systemUptime
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var endedAt: TimeInterval?
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    init() { (audio, continuation) = AsyncThrowingStream.makeStream() }
    func enqueue(_ samples: [Float]) {
        lock.withLock {
            guard !closed, !isCancelledLocked else { return }
            guard bufferedSamples + samples.count <= 16_000 * 15 else {
                closed = true
                continuation.finish(throwing: DoubaoError.backlog)
                return
            }
            bufferedSamples += samples.count
            continuation.yield(samples)
        }
    }
    func consumed(_ count: Int) {
        lock.withLock { bufferedSamples -= count; lastProgress = ProcessInfo.processInfo.systemUptime }
    }
    func markConnected() { lock.withLock { connected = true } }
    func markFinalSent() { lock.withLock { finalSent = true } }
    var finalWasSent: Bool { lock.withLock { finalSent } }
    func hasTimedOut(limit: TimeInterval) -> Bool {
        lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            return (!connected && now - startedAt > min(10, limit))
                || (bufferedSamples > 0 && now - lastProgress > min(10, limit))
                || endedAt.map { now - $0 > limit } == true
        }
    }
    func endAudio() {
        lock.withLock {
            if endedAt == nil { endedAt = ProcessInfo.processInfo.systemUptime }
            closed = true
            continuation.finish()
        }
    }
    func closeMailbox() { lock.withLock { closed = true; continuation.finish() } }
    func abort(_ error: Error) { lock.withLock { closed = true; continuation.finish(throwing: error) } }
    func cancel() {
        lock.withLock { isCancelledLocked = true; closed = true; onPartial = nil; continuation.finish() }
        resolve(.failure(CancellationError()))
    }
    func resolve(_ result: Result<String, Error>) {
        let waiter = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            closed = true
            continuation.finish()
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }
    func value() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<String, Error>? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}
