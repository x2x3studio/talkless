import AVFoundation
import Foundation
import Testing
@testable import Talkless

private func responseFrame(_ text: String?, final: Bool = false, compressed: Bool = true, sequence: Bool = true) throws -> Data {
    let body = try JSONSerialization.data(withJSONObject: text.map { ["result": ["text": $0]] } ?? [:])
    let payload = compressed ? try DoubaoProtocol.gzip(body, decompress: false) : body
    var data = Data([0x11, 0x90 | (final ? 2 : 0) | (sequence ? 1 : 0), compressed ? 0x11 : 0x10, 0])
    if sequence { var value = (final ? Int32(-4) : Int32(2)).bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
    var size = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
    data.append(payload)
    return data
}

/// The sender gets an acknowledgment, then a partial and final transcript. No general
/// clipboard, microphone, user settings or real network connections are used.
private final class ScriptedDoubaoSocket: DoubaoSocket, @unchecked Sendable {
    let lock = NSLock()
    private var packets: [Data] = []
    private var closed = false
    private let events: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    var respond = true
    var failAudio = false
    init() { (events, continuation) = AsyncThrowingStream.makeStream() }
    var sent: [Data] { lock.withLock { packets } }
    func send(_ data: Data) async throws {
        let allowed = lock.withLock { () -> Bool in
            guard !closed else { return false }
            packets.append(data)
            return true
        }
        guard allowed else { throw CancellationError() }
        if failAudio, data[1] >> 4 == 2 { throw URLError(.networkConnectionLost) }
        guard respond else { return }
        if data[1] >> 4 == 1 { continuation.yield(try responseFrame(nil)) }
        else if data[1] & 2 != 0 { continuation.yield(try responseFrame("Final words", final: true)) }
        else { continuation.yield(try responseFrame("Live words")) }
    }
    func receive() async throws -> Data {
        var iterator = events.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CancellationError() }
        return data
    }
    func close() { lock.withLock { closed = true }; continuation.finish(throwing: CancellationError()) }
}

private actor ValidationGate {
    private var continuation: CheckedContinuation<Void, Error>?
    var ready: Bool { continuation != nil }
    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

@Suite struct DoubaoTests {
    @Test func connectionCheckSendsNoAudio() async throws {
        let socket = ScriptedDoubaoSocket()
        try await DoubaoTranscriptionSession.validateConnection(config: .init(apiKey: "synthetic"), socket: socket)
        #expect(socket.sent.count == 1)
        #expect(socket.sent.first?[1] == 0x10, "Only configuration, never an audio packet")
        let silent = ScriptedDoubaoSocket(); silent.respond = false
        do {
            try await DoubaoTranscriptionSession.validateConnection(config: .init(apiKey: "synthetic"), socket: silent, timeout: 0.1)
            Issue.record("Expected timeout")
        } catch { #expect(error is DoubaoError) }
        let invalid = ScriptedDoubaoSocket()
        do {
            try await DoubaoTranscriptionSession.validateConnection(config: .init(apiKey: ""), socket: invalid)
            Issue.record("Expected configuration error")
        } catch { #expect(invalid.sent.isEmpty) }
    }

    @MainActor @Test func connectionReceiptIsInvalidatedAndErrorsAreSanitized() async throws {
        let gate = ValidationGate()
        let check = DoubaoConnectionCheck { _ in try await gate.wait() }
        check.start(.init(apiKey: "synthetic"))
        while !(await gate.ready) { await Task.yield() }
        #expect(check.isChecking)
        check.invalidate()
        await gate.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(!check.isChecking && check.outcome == nil, "Stale completion cannot verify a new key")
        let failed = DoubaoConnectionCheck { _ in
            throw NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "secret-key-echo"])
        }
        failed.start(.init(apiKey: "synthetic"))
        while failed.isChecking { await Task.yield() }
        if case .failure(let message) = failed.outcome { #expect(!message.contains("secret-key-echo")) }
        else { Issue.record("Expected sanitized failure") }
        let success = DoubaoConnectionCheck { _ in }
        success.start(.init(apiKey: "synthetic"))
        while success.isChecking { await Task.yield() }
        #expect(success.outcome == .success)
        success.invalidate()
        #expect(success.outcome == nil)
    }

    @Test func headersAndConfiguration() throws {
        let request = try DoubaoConfig(apiKey: "synthetic-key").request()
        #expect(request.url?.host == "openspeech.bytedance.com")
        #expect(request.url?.scheme == "wss")
        #expect(request.value(forHTTPHeaderField: "X-Api-Key") == "synthetic-key")
        #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
        #expect(request.value(forHTTPHeaderField: "X-Api-Sequence") == "-1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(!DoubaoConfig(apiKey: "").isConfigured)
        #expect(!DoubaoConfig(apiKey: "key\r\nInjected: value").isConfigured)
        let frame = try DoubaoProtocol.configuration()
        #expect(Array(frame.prefix(4)) == [0x11, 0x10, 0x11, 0])
        let body = try DoubaoProtocol.gzip(Data(frame.dropFirst(8)), decompress: true)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["audio"] as? [String: Any])?["rate"] as? Int == 16000)
        #expect((json["request"] as? [String: Any])?["result_type"] as? String == "full")
        #expect(!String(decoding: body, as: UTF8.self).contains("synthetic-key"))
    }

    @Test func compressedAndPlainResponses() throws {
        for compressed in [false, true] {
            for sequence in [false, true] {
                #expect(try DoubaoProtocol.response(responseFrame("partial", compressed: compressed, sequence: sequence))
                        == .init(text: "partial", isFinal: false))
                #expect(try DoubaoProtocol.response(responseFrame("final", final: true, compressed: compressed, sequence: sequence))
                        == .init(text: "final", isFinal: true))
            }
        }
        #expect(throws: DoubaoError.self) { try DoubaoProtocol.response(responseFrame(nil, final: true)) }
        #expect(throws: DoubaoError.self) { try DoubaoProtocol.response(Data([0x11, 0x93, 0x11, 0])) }
        var valid = try responseFrame("safe")
        valid.removeLast()
        #expect(throws: DoubaoError.self) { try DoubaoProtocol.response(valid) }
        let error = Data([0x11, 0xf0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 6]) + Data("secret".utf8)
        do { _ = try DoubaoProtocol.response(error); Issue.record("Expected server error") }
        catch { #expect(!error.localizedDescription.contains("secret")) }
    }

    @Test func gzipAndPCM() throws {
        for value in [Data(), Data("synthetic text".utf8), Data(repeating: 1, count: 70_000)] {
            #expect(try DoubaoProtocol.gzip(DoubaoProtocol.gzip(value, decompress: false), decompress: true) == value)
        }
        #expect(throws: DoubaoError.self) { try DoubaoProtocol.gzip(Data([1, 2, 3]), decompress: true) }
        let samples: [Float] = [0, 1, -1, .nan, .infinity]
        #expect(samples.withUnsafeBufferPointer { DoubaoProtocol.pcm16($0) } == Data([0, 0, 255, 127, 1, 128, 0, 0, 0, 0]))
        let final = try DoubaoProtocol.audio(Data(), final: true)
        #expect(final[1] == 0x22)
    }

    @MainActor @Test func streamsAudioAndReturnsOnlyFinal() async throws {
        let socket = ScriptedDoubaoSocket()
        let session = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: socket, timeout: 30)
        var previews: [String] = []
        session.onPartial = { previews.append($0) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3_201)!
        audio.frameLength = 3_201
        audio.floatChannelData![0].initialize(repeating: 0.25, count: 3_201)
        session.feed(audio)
        let result = try await session.finish(samples: [Float](repeating: 1, count: 3_201))
        #expect(result == "Final words")
        #expect(previews.contains("Live words"))
        let packets = socket.sent
        #expect(packets.count == 3, "One config, one 200 ms audio packet, one final tail")
        #expect(packets[0][1] == 0x10 && packets[1][1] == 0x20 && packets[2][1] == 0x22)
        let audioBytes = try packets.dropFirst().map { try DoubaoProtocol.gzip(Data($0.dropFirst(8)), decompress: true).count }.reduce(0, +)
        #expect(audioBytes == 6_402, "Recorder samples passed to finish must not be sent again")
    }

    @Test func sendFailureAndOversizedBacklogFailClosed() async throws {
        let socket = ScriptedDoubaoSocket(); socket.failAudio = true
        let failed = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: socket, timeout: 1)
        do { _ = try await failed.finish(samples: []); Issue.record("Expected send failure") }
        catch { #expect(error is DoubaoError) }
        let backlog = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: ScriptedDoubaoSocket())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000 * 16)!
        audio.frameLength = audio.frameCapacity
        audio.floatChannelData![0].initialize(repeating: 0, count: Int(audio.frameLength))
        backlog.feed(audio)
        do { _ = try await backlog.finish(samples: []); Issue.record("Expected bounded backlog failure") }
        catch { #expect(error is DoubaoError) }
    }

    @Test func cancelAndTimeoutNeverReturnPreview() async throws {
        let socket = ScriptedDoubaoSocket(); socket.respond = false
        let session = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: socket, timeout: 0.15)
        do { _ = try await session.finish(samples: []); Issue.record("Expected timeout") }
        catch { #expect(error is DoubaoError) }
        let cancelled = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: ScriptedDoubaoSocket())
        cancelled.cancel()
        do { _ = try await cancelled.finish(samples: []); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }
}
