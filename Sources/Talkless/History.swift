import Foundation

struct HistoryEntry: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case dictation, edit, translation }

    var id = UUID()
    var date = Date()
    var kind: Kind
    var app: String
    var raw: String
    var output: String
    var duration: TimeInterval
}

/// Store recent dictation history locally (text only, not audio).
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 500

    @Published private(set) var entries: [HistoryEntry] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
        }
    }

    func add(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func delete(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    /// Total dictated character count for statistics in Settings.
    var totalCharacters: Int {
        entries.filter { $0.kind == .dictation }.reduce(0) { $0 + $1.output.count }
    }

    var totalDuration: TimeInterval {
        entries.reduce(0) { $0 + $1.duration }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }
}
