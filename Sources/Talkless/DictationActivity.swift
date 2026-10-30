import Combine
import Foundation

/// Text-free daily totals. Characters are Swift extended grapheme clusters in the final output,
/// not words or model tokens. Only dictations made after tracking starts contribute.
struct DictationActivityDay: Codable, Equatable, Identifiable, Sendable {
    var day: String
    var characters: Int
    var dictations: Int
    var duration: TimeInterval

    var id: String { day }
}

/// Independent of HistoryStore: never reads history or initializes that singleton itself.
/// Deleting transcript history leaves these local totals intact; reset() clears them separately.
@MainActor
final class DictationActivityStore: ObservableObject {
    static let shared = DictationActivityStore()
    static let retentionDays = 400
    static let recentIDLimit = 500

    private struct Receipt: Codable {
        var id: UUID
        var day: String
    }

    private struct Snapshot: Codable {
        var version = 1
        var trackingStartedAt: Date
        var timeZoneIdentifier: String
        var days: [DictationActivityDay] = []
        // Bounded retry protection, not an unlimited event log. History has at most 500 entries
        // and existing history is never imported. Replaying a UUID after 500 newer
        // records is outside this deduplication window; normal History.add inserts each ID once.
        var recentIDs: [Receipt] = []
    }

    @Published private var snapshot: Snapshot
    @Published private(set) var errorMessage: String?
    private let url: URL
    private let now: () -> Date

    var trackingStartedAt: Date { snapshot.trackingStartedAt }
    var timeZoneIdentifier: String { snapshot.timeZoneIdentifier }
    var calendar: Calendar { Self.calendar(timeZone: TimeZone(identifier: timeZoneIdentifier)!) }

    /// Only populated days, oldest first. An absent day before coverageStartDay is unrecorded,
    /// not zero. The first day may start partway through the day.
    var days: [DictationActivityDay] {
        let lowerBound = oldestRetainedDay(at: now())
        let today = dayKey(for: now())
        return snapshot.days.filter { $0.day >= lowerBound && $0.day <= today }
    }

    /// First fully tracked civil day (clamped to retention). Starting/resetting mid-day does
    /// not establish a complete zero for that day; earlier days were not recorded.
    var coverageStartDay: String {
        let start = calendar.startOfDay(for: trackingStartedAt)
        let firstCompleteDay = trackingStartedAt == start
            ? start : calendar.date(byAdding: .day, value: 1, to: start)!
        return max(dayKey(for: firstCompleteDay), oldestRetainedDay(at: now()))
    }

    init(url: URL? = nil, now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless", isDirectory: true)
            .appendingPathComponent("activity.json")
        self.now = now
        let instant = now()
        let initial = Snapshot(trackingStartedAt: instant, timeZoneIdentifier: timeZone.identifier)
        var loaded = initial
        var readError: String?
        do {
            let data = try Data(contentsOf: self.url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let decoded = try decoder.decode(Snapshot.self, from: data)
            guard Self.isValid(decoded) else { throw ActivityError.invalidFile }
            loaded = decoded
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // New installations track from now; existing transcript history is never imported.
        } catch {
            // A damaged/unsupported file cannot establish earlier coverage.
            readError = L10n.tr("Activity data could not be read. Tracking restarted from now.")
        }
        snapshot = loaded
        errorMessage = readError
        prune(&loaded, at: instant)
        snapshot = loaded
        // Persist the baseline immediately, even before the first dictation.
        if !persist(loaded) { errorMessage = L10n.tr("Activity data could not be saved.") }
    }

    func dayKey(for date: Date) -> String {
        Self.dayKey(for: date, calendar: calendar)
    }

    func date(forDay day: String) -> Date? {
        Self.date(forDay: day, calendar: calendar)
    }

    func record(_ entry: HistoryEntry) {
        let instant = now()
        var updated = snapshot
        prune(&updated, at: instant)
        append(entry, to: &updated, at: instant)
        prune(&updated, at: instant)
        commit(updated)
    }

    /// Returns false without clearing in-memory totals if the new baseline cannot be saved.
    /// Keeps the time zone and refuses pre-reset records. History is never imported.
    @discardableResult
    func reset() -> Bool {
        let updated = Snapshot(trackingStartedAt: now(), timeZoneIdentifier: timeZoneIdentifier)
        return commit(updated, keepOnFailure: false)
    }

    private func append(_ entry: HistoryEntry, to updated: inout Snapshot, at instant: Date) {
        guard entry.kind == .dictation,
              entry.date.timeIntervalSince1970.isFinite, entry.date <= instant,
              entry.date >= updated.trackingStartedAt,
              entry.duration.isFinite, entry.duration >= 0,
              !updated.recentIDs.contains(where: { $0.id == entry.id }) else { return }
        let day = dayKey(for: entry.date)
        guard date(forDay: day) != nil, day >= oldestRetainedDay(at: instant) else { return }
        let index = updated.days.firstIndex(where: { $0.day == day })
        var total = index.map { updated.days[$0] }
            ?? DictationActivityDay(day: day, characters: 0, dictations: 0, duration: 0)
        let characters = total.characters.addingReportingOverflow(entry.output.count)
        let dictations = total.dictations.addingReportingOverflow(1)
        let duration = total.duration + entry.duration
        guard !characters.overflow, !dictations.overflow, duration.isFinite else { return }
        total.characters = characters.partialValue
        total.dictations = dictations.partialValue
        total.duration = duration
        if let index { updated.days[index] = total } else { updated.days.append(total) }
        updated.days.sort { $0.day < $1.day }
        updated.recentIDs.append(Receipt(id: entry.id, day: day))
        if updated.recentIDs.count > Self.recentIDLimit {
            updated.recentIDs.removeFirst(updated.recentIDs.count - Self.recentIDLimit)
        }
    }

    private func oldestRetainedDay(at date: Date) -> String {
        let start = calendar.startOfDay(for: date)
        return dayKey(for: calendar.date(byAdding: .day, value: -(Self.retentionDays - 1), to: start)!)
    }

    private func prune(_ updated: inout Snapshot, at instant: Date) {
        let oldest = oldestRetainedDay(at: instant)
        // A backward wall-clock adjustment must not destroy already recorded future buckets.
        // Reads hide them until the clock catches up; only genuinely expired days are removed.
        updated.days.removeAll { $0.day < oldest }
        if updated.days.count > Self.retentionDays {
            updated.days.removeFirst(updated.days.count - Self.retentionDays)
        }
        let populatedDays = Set(updated.days.map(\.day))
        updated.recentIDs.removeAll { !populatedDays.contains($0.day) }
    }

    @discardableResult
    private func commit(_ updated: Snapshot, keepOnFailure: Bool = true) -> Bool {
        guard persist(updated) else {
            // Retry pending counts with the next write, while still telling the UI they are
            // not durable. Reset is different: do not claim a clear that failed on disk.
            if keepOnFailure { snapshot = updated }
            errorMessage = L10n.tr("Activity data could not be saved. Some dictations may be missing.")
            return false
        }
        snapshot = updated
        errorMessage = nil
        return true
    }

    private func persist(_ updated: Snapshot) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(updated)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            return false
        }
    }

    private enum ActivityError: Error { case invalidFile }

    private static func calendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", locale: Locale(identifier: "en_US_POSIX"),
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(forDay day: String, calendar: Calendar) -> Date? {
        let bytes = Array(day.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) })
        else { return nil }
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]),
              (1...31).contains(parts[2]),
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayKey(for: date, calendar: calendar) == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func isValid(_ snapshot: Snapshot) -> Bool {
        guard snapshot.version == 1,
              snapshot.trackingStartedAt.timeIntervalSince1970.isFinite,
              let timeZone = TimeZone(identifier: snapshot.timeZoneIdentifier),
              snapshot.days.count <= retentionDays,
              snapshot.recentIDs.count <= recentIDLimit else { return false }
        let calendar = calendar(timeZone: timeZone)
        let trackingDay = dayKey(for: snapshot.trackingStartedAt, calendar: calendar)
        guard date(forDay: trackingDay, calendar: calendar) != nil,
              Set(snapshot.days.map(\.day)).count == snapshot.days.count,
              snapshot.days.map(\.day) == snapshot.days.map(\.day).sorted(),
              Set(snapshot.recentIDs.map(\.id)).count == snapshot.recentIDs.count else { return false }
        let populatedDays = Set(snapshot.days.map(\.day))
        return snapshot.days.allSatisfy {
            date(forDay: $0.day, calendar: calendar) != nil && $0.day >= trackingDay
                && $0.characters >= 0 && $0.dictations > 0 && $0.duration.isFinite && $0.duration >= 0
        } && snapshot.recentIDs.allSatisfy { populatedDays.contains($0.day) }
    }
}
