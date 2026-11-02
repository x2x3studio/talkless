import Foundation
import zlib

/// Doubao streaming ASR v3. Protocol reference: https://www.volcengine.com/docs/6561/1354869
/// Only the ASR service is used; this key is not a Volcengine Ark/chat-model key.
enum DoubaoResource: String, CaseIterable, Identifiable, Sendable {
    case duration = "volc.seedasr.sauc.duration"
    case concurrent = "volc.seedasr.sauc.concurrent"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .duration: L10n.tr("ASR 2.0 · Duration billing")
        case .concurrent: L10n.tr("ASR 2.0 · Concurrent billing")
        }
    }
}

struct DoubaoConfig: Sendable, Equatable {
    var apiKey: String
    var resource: DoubaoResource = .duration

    var isConfigured: Bool { (try? request()) != nil }

    func request() throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.allSatisfy({ (33...126).contains($0) }) else { throw DoubaoError.configuration }
        var request = URLRequest(url: URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!, timeoutInterval: 10)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resource.rawValue, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        return request
    }
}

enum DoubaoError: LocalizedError {
    case configuration, authentication, connection, timeout, invalidResponse, backlog, invalidAudio
    case service(UInt32)
    var errorDescription: String? {
        switch self {
        case .configuration: L10n.tr("Enter a Doubao Speech API key in Speech recognition settings.")
        case .authentication: L10n.tr("Doubao rejected this key. Make sure it is a Doubao Speech key, not an Ark (LLM) key, and that the plan under More options matches your console.")
        case .connection: L10n.tr("Could not connect to Doubao. Check your network and try again.")
        case .timeout: L10n.tr("Doubao recognition timed out. Check your network and try again.")
        case .invalidResponse: L10n.tr("Doubao returned an invalid recognition response. No partial text was inserted.")
        case .backlog: L10n.tr("The connection cannot keep up with recording. Check your network and start again.")
        case .invalidAudio: L10n.tr("Doubao recognition requires 16 kHz mono audio.")
        case .service(let code): L10n.format("Doubao recognition failed (code %lld). Check your key, resource and service quota.", Int64(code))
        }
    }
}

/// Binary framing and bounded gzip decoding, independent of WebSocket or audio capture.
enum DoubaoProtocol {
    static let maximumPayload = 1_048_576
    static let packetBytes = 6_400 // 200 ms, 16 kHz mono signed PCM16 little endian.
    struct Response: Equatable, Sendable {
        let text: String?
        let isFinal: Bool
    }

    static func configuration() throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            // Random per session, not a persistent user or device identifier.
            "user": ["uid": UUID().uuidString],
            "audio": ["format": "pcm", "codec": "raw", "rate": 16000, "bits": 16, "channel": 1],
            "request": ["model_name": "bigmodel", "result_type": "full", "enable_itn": true,
                        "enable_punc": true, "enable_ddc": false, "show_utterances": true],
        ])
        return try frame(type: 1, flags: 0, serialization: 1, payload: payload)
    }

    static func audio(_ pcm: Data, final: Bool) throws -> Data {
        try frame(type: 2, flags: final ? 2 : 0, serialization: 0, payload: pcm)
    }

    private static func frame(type: UInt8, flags: UInt8, serialization: UInt8, payload: Data) throws -> Data {
        let compressed = try gzip(payload, decompress: false)
        var data = Data([0x11, type << 4 | flags, serialization << 4 | 1, 0])
        var size = UInt32(compressed.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(compressed)
        return data
    }

    static func response(_ data: Data) throws -> Response {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.count <= maximumPayload + 1024, bytes[0] >> 4 == 1 else { throw DoubaoError.invalidResponse }
        let headerSize = Int(bytes[0] & 15) * 4
        guard headerSize >= 4, headerSize <= bytes.count - 4 else { throw DoubaoError.invalidResponse }
        let type = bytes[1] >> 4, flags = bytes[1] & 15
        let serialization = bytes[2] >> 4, compression = bytes[2] & 15
        guard flags <= 3, compression <= 1 else { throw DoubaoError.invalidResponse }
        var offset = headerSize
        func readUInt32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else { throw DoubaoError.invalidResponse }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        var errorCode: UInt32?
        if type == 15 { errorCode = try readUInt32() }
        else {
            guard type == 9, serialization == 1 else { throw DoubaoError.invalidResponse }
            if flags & 1 != 0 { _ = try readUInt32() }
        }
        let size = Int(try readUInt32())
        guard size <= maximumPayload, offset + size == bytes.count else { throw DoubaoError.invalidResponse }
        if let errorCode { throw DoubaoError.service(errorCode) } // Never surface provider body/credentials.
        let payload = Data(bytes[offset...])
        let json = compression == 1 ? try gzip(payload, decompress: true) : payload
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { throw DoubaoError.invalidResponse }
        if let code = object["code"] as? NSNumber, code.uint32Value != 20_000_000 {
            throw DoubaoError.service(code.uint32Value)
        }
        // v3 documents an object; some deployments return a one-element result array.
        let result: [String: Any]?
        if let value = object["result"] as? [String: Any] { result = value }
        else if let values = object["result"] as? [[String: Any]], values.count <= 1 { result = values.first }
        else if object["result"] == nil { result = nil }
        else { throw DoubaoError.invalidResponse }
        let text = result?["text"] as? String
        guard result?["text"] == nil || text != nil else { throw DoubaoError.invalidResponse }
        // Silence can end successfully without a result or text field.
        return Response(text: text, isFinal: flags & 2 != 0)
    }

    static func pcm16(_ samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = sample.isFinite ? max(-1, min(1, sample)) : 0
            var pcm = Int16(value * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &pcm) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func gzip(_ data: Data, decompress: Bool) throws -> Data {
        guard data.count <= maximumPayload else { throw DoubaoError.invalidResponse }
        var stream = z_stream()
        let status = decompress
            ? inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            : deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw DoubaoError.invalidResponse }
        defer { if decompress { inflateEnd(&stream) } else { deflateEnd(&stream) } }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var result = Data()
            var output = [UInt8](repeating: 0, count: 16_384)
            while true {
                let code = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return decompress ? inflate(&stream, Z_NO_FLUSH) : deflate(&stream, Z_FINISH)
                }
                let count = output.count - Int(stream.avail_out)
                guard result.count + count <= maximumPayload else { throw DoubaoError.invalidResponse }
                result.append(contentsOf: output.prefix(count))
                if code == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw DoubaoError.invalidResponse }
                    return result
                }
                guard code == Z_OK, count > 0 else { throw DoubaoError.invalidResponse }
            }
        }
    }
}
