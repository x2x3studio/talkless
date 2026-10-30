import Combine
import Foundation

// Production History.swift can be compiled without settings, models, or any real singleton.
@MainActor final class DictionaryReviewStore {
    static let shared = DictionaryReviewStore()
    func observeHistory(_ publisher: AnyPublisher<[HistoryEntry], Never>) {
        fatalError("Synthetic activity tests must not initialize dictionary review")
    }
}

@MainActor private final class TestClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@main
struct ActivityTests {
    @MainActor
    static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
        func file(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathComponent("activity.json") }
        func entry(_ instant: Date, output: String = "hello", duration: Double = 2,
                   kind: HistoryEntry.Kind = .dictation, id: UUID = UUID()) -> HistoryEntry {
            HistoryEntry(id: id, date: instant, kind: kind, app: "PRIVATE APP SENTINEL",
                         raw: "PRIVATE RAW SENTINEL", output: output, duration: duration)
        }
        func json(_ url: URL) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        }
        func writeJSON(_ value: [String: Any], to url: URL) throws {
            try JSONSerialization.data(withJSONObject: value).write(to: url, options: .atomic)
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        let clock = TestClock(date("2024-02-29T04:30:00Z"))
        let url = file("basic")
        let store = DictationActivityStore(url: url, now: { clock.date }, timeZone: utc)
        check(store.days.isEmpty, "new statistics empty")
        check(store.trackingStartedAt == clock.date, "baseline is actual initialization")
        check(store.coverageStartDay == "2024-03-01", "partial leap day starts full coverage tomorrow")
        check(store.errorMessage == nil, "missing file is a clean first launch")
        check(FileManager.default.fileExists(atPath: url.path), "baseline persisted even without history")
        check(store.date(forDay: "2024-02-29") != nil, "valid leap day")
        for invalid in ["2023-02-29", "2024-02-30", "2024-13-01", "2024-00-01", "2024-01-00",
                        "2024-2-29", "2024-02-29x", "0000-01-01", "2024/01/01", "2024-１２-01"] {
            check(store.date(forDay: invalid) == nil, "invalid date \(invalid) rejected")
        }
        let unicode = "e\u{301}\u{1F469}\u{200D}\u{1F4BB}\u{1F1E8}\u{1F1F3}\u{4E2D}"
        check(unicode.count == 4, "fixture uses composed Unicode graphemes")
        let old = entry(date("2024-02-29T04:30:00Z"), output: unicode, duration: 3.5)
        for value in [old, old, entry(clock.date, kind: .edit), entry(clock.date, kind: .translation)] { store.record(value) }
        check(store.days == [DictationActivityDay(day: "2024-02-29", characters: 4, dictations: 1, duration: 3.5)], "only unique dictation output graphemes counted")
        clock.date = date("2024-03-10T12:00:00Z")
        check(store.coverageStartDay == "2024-03-01", "advancing clock preserves original coverage")
        let fresh = entry(clock.date, output: "PRIVATE OUTPUT SENTINEL", duration: 1.25)
        store.record(fresh)
        store.record(fresh)
        check(store.days.last?.dictations == 1, "duplicate record idempotent")
        check(store.days.last?.characters == fresh.output.count, "final output character count")
        check(store.days.last?.duration == 1.25, "fractional duration retained")
        let persisted = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        for secret in ["PRIVATE APP SENTINEL", "PRIVATE RAW SENTINEL", "PRIVATE OUTPUT SENTINEL", unicode] {
            check(!persisted.contains(secret), "aggregate contains no transcript or app data")
        }
        let restarted = DictationActivityStore(url: url, now: { clock.date }, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
        restarted.record(old)
        restarted.record(fresh)
        check(restarted.days == store.days, "recent dedupe durable across restart")
        check(restarted.timeZoneIdentifier == utc.identifier, "persisted timezone does not shift when machine zone changes")
        check(restarted.trackingStartedAt == store.trackingStartedAt, "baseline survives restart")
        let beforeInvalid = restarted.days
        for duration in [-1.0, Double.nan, Double.infinity, -Double.infinity] {
            restarted.record(entry(clock.date, duration: duration))
        }
        restarted.record(entry(clock.date.addingTimeInterval(1)))
        restarted.record(entry(Date(timeIntervalSince1970: .nan)))
        restarted.record(entry(Date(timeIntervalSince1970: .infinity)))
        restarted.record(entry(store.trackingStartedAt.addingTimeInterval(-1)))
        restarted.record(entry(clock.date, kind: .translation))
        restarted.record(entry(clock.date, kind: .edit))
        check(restarted.days == beforeInvalid, "invalid duration/date, future, before baseline and other kinds excluded")
        let empty = entry(clock.date, output: "", duration: 0)
        restarted.record(empty)
        check(restarted.days.last?.dictations == 2, "zero-duration empty dictation still a dictation")
        check(restarted.days.last?.characters == fresh.output.count, "empty output contributes no characters")
        let durationStore = DictationActivityStore(url: file("duration-overflow"), now: { clock.date }, timeZone: utc)
        durationStore.record(entry(clock.date, duration: Double.greatestFiniteMagnitude))
        durationStore.record(entry(clock.date, duration: Double.greatestFiniteMagnitude))
        check(durationStore.days.first?.dictations == 1, "duration addition overflow rejects the whole new event")
        check(durationStore.days.first?.duration.isFinite == true, "aggregate duration remains JSON-safe finite")

        // Actual calendar days rather than 24-hour arithmetic: leap, UTC offsets and both DST edges.
        let laClock = TestClock(date("2024-03-11T12:00:00Z"))
        let laURL = file("los-angeles")
        let la = DictationActivityStore(url: laURL, now: { laClock.date }, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        check(la.dayKey(for: date("2024-03-10T07:59:59Z")) == "2024-03-09", "pre-midnight local date independent of UTC")
        check(la.dayKey(for: date("2024-03-10T08:00:00Z")) == "2024-03-10", "local midnight boundary")
        check(la.dayKey(for: date("2024-03-10T09:59:59Z")) == "2024-03-10", "before spring DST change")
        check(la.dayKey(for: date("2024-03-10T10:00:00Z")) == "2024-03-10", "after spring DST change")
        check(la.date(forDay: "2024-03-11")!.timeIntervalSince(la.date(forDay: "2024-03-10")!) == 23 * 3600, "spring day really has 23 hours")
        check(la.date(forDay: "2024-11-04")!.timeIntervalSince(la.date(forDay: "2024-11-03")!) == 25 * 3600, "fall day really has 25 hours")
        check(la.dayKey(for: date("2024-11-03T08:30:00Z")) == "2024-11-03"
              && la.dayKey(for: date("2024-11-03T09:30:00Z")) == "2024-11-03", "both repeated DST hours stay one day")
        let kathmandu = DictationActivityStore(url: file("nepal"), now: { laClock.date }, timeZone: TimeZone(identifier: "Asia/Kathmandu")!)
        check(kathmandu.dayKey(for: date("2024-02-28T18:14:59Z")) == "2024-02-28", "fractional timezone before midnight")
        check(kathmandu.dayKey(for: date("2024-02-28T18:15:00Z")) == "2024-02-29", "fractional timezone leap midnight")
        let midnight = DictationActivityStore(url: file("midnight"), now: { date("2024-03-10T08:00:00Z") }, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        check(midnight.coverageStartDay == "2024-03-10", "starting exactly at local midnight covers that day")

        // Keep 400 civil days inclusive of today, regardless of DST and history's 500-entry cap.
        let retentionURL = file("retention")
        let today = la.calendar.startOfDay(for: laClock.date)
        laClock.date = la.calendar.date(byAdding: .day, value: -409, to: today)!
        let retention = DictationActivityStore(url: retentionURL, now: { laClock.date }, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        for offset in (0..<410).reversed() {
            laClock.date = retention.calendar.date(byAdding: .day, value: -offset, to: today)!
            retention.record(entry(laClock.date, output: "x"))
        }
        check(retention.days.count == 400, "rolling 400-day cap")
        check(retention.days.first?.day == retention.dayKey(for: retention.calendar.date(byAdding: .day, value: -399, to: today)!), "oldest included day exactly 399 calendar days ago")
        laClock.date = retention.calendar.date(byAdding: .day, value: 1, to: laClock.date)!
        check(retention.days.count == 399, "in-memory reads hide expired day even without writes")
        let retentionRestart = DictationActivityStore(url: retentionURL, now: { laClock.date }, timeZone: utc)
        check(retentionRestart.days.count == 399, "restart prunes expired totals")
        let retainedJSON = try json(retentionURL)
        check((retainedJSON["days"] as! [Any]).count == 399, "pruned disk file stays compact")
        laClock.date = retention.calendar.date(byAdding: .day, value: 500, to: laClock.date)!
        let expired = DictationActivityStore(url: retentionURL, now: { laClock.date }, timeZone: utc)
        check(expired.days.isEmpty, "all ancient totals expire")
        check(expired.coverageStartDay == expired.dayKey(for: expired.calendar.date(byAdding: .day, value: -399, to: laClock.date)!), "coverage clamped to retention window")

        // Receipt set is deliberately bounded. Ordinary record paths never replay entries older
        // than this window; arbitrary unlimited old replay is not guaranteed.
        let boundedURL = file("bounded")
        let bounded = DictationActivityStore(url: boundedURL, now: { clock.date }, timeZone: utc)
        var latest = entry(clock.date)
        for _ in 0..<505 {
            latest = entry(clock.date, output: "x", duration: 1)
            bounded.record(latest)
        }
        bounded.record(latest)
        check(bounded.days.first?.dictations == 505, "more than 500 records preserve totals and latest duplicate blocked")
        let boundedJSON = try json(boundedURL)
        let boundedData = try Data(contentsOf: boundedURL)
        check((boundedJSON["recentIDs"] as! [Any]).count == 500, "persistent UUID receipts bounded at 500")
        check(boundedData.count < 60_000, "busy-day file remains compact")

        // Reset persists a new baseline and keeps text history intact.
        clock.date = clock.date.addingTimeInterval(60)
        check(restarted.reset(), "reset saved")
        check(restarted.days.isEmpty && restarted.trackingStartedAt == clock.date, "reset empties stats and restarts baseline")
        restarted.record(fresh)
        check(restarted.days.isEmpty, "reset cannot be undone by old record")
        let resetRestart = DictationActivityStore(url: url, now: { clock.date }, timeZone: utc)
        check(resetRestart.days.isEmpty, "reset durable across restart")
        resetRestart.record(entry(clock.date))
        check(resetRestart.days.first?.dictations == 1, "new dictation works after reset")

        let historyDirectory = root.appendingPathComponent("history-integration")
        try FileManager.default.createDirectory(at: historyDirectory, withIntermediateDirectories: true)
        let historyURL = historyDirectory.appendingPathComponent("history.json")
        let historyActivityURL = historyDirectory.appendingPathComponent("activity.json")
        let historyEncoder = JSONEncoder()
        historyEncoder.dateEncodingStrategy = .iso8601
        try historyEncoder.encode([old]).write(to: historyURL, options: .atomic)
        let historyActivity = DictationActivityStore(url: historyActivityURL, now: { clock.date }, timeZone: utc)
        let history = HistoryStore(url: historyURL, activity: historyActivity, observeDictionaryReview: false)
        check(historyActivity.days.isEmpty, "History init never imports preexisting history")
        let current = entry(clock.date)
        history.add(current)
        history.add(entry(clock.date, kind: .translation))
        history.add(entry(clock.date, kind: .edit))
        check(historyActivity.days.last?.dictations == 1, "History add records dictation only")
        history.delete(current)
        history.clear()
        check(history.entries.isEmpty, "history clear removes text entries")
        check(historyActivity.days.count == 1, "history delete/clear preserve independent text-free totals")
        history.add(entry(clock.date))
        check(historyActivity.reset(), "activity-only clear succeeds")
        check(history.entries.count == 1, "activity clear preserves history text")
        let historyReloadActivity = DictationActivityStore(url: historyActivityURL, now: { clock.date }, timeZone: utc)
        _ = HistoryStore(url: historyURL, activity: historyReloadActivity, observeDictionaryReview: false)
        check(historyReloadActivity.days.isEmpty, "History init does not resurrect reset activity")
        for _ in 0..<502 { history.add(entry(clock.date, output: "x")) }
        check(history.entries.count == 500, "history cap remains 500")
        check(historyActivity.days.first?.dictations == 502, "history truncation does not truncate activity totals")

        // Backward wall-clock changes hide future buckets but never erase recorded activity.
        let rollbackURL = file("clock-rollback")
        let rollbackClock = TestClock(date("2024-03-10T23:59:00Z"))
        let rollback = DictationActivityStore(url: rollbackURL, now: { rollbackClock.date }, timeZone: utc)
        rollback.record(entry(rollbackClock.date))
        rollbackClock.date = date("2024-03-11T00:01:00Z")
        let futureBucketEntry = entry(rollbackClock.date)
        rollback.record(futureBucketEntry)
        let originalBaseline = rollback.trackingStartedAt
        rollbackClock.date = date("2024-03-10T23:58:00Z")
        let rolledBack = DictationActivityStore(url: rollbackURL, now: { rollbackClock.date }, timeZone: utc)
        check(rolledBack.errorMessage == nil && rolledBack.trackingStartedAt == originalBaseline, "clock rollback keeps future baseline valid")
        check(rolledBack.days.count == 1, "future stored bucket temporarily hidden")
        rolledBack.record(entry(rollbackClock.date))
        let rolledJSON = try json(rollbackURL)
        check((rolledJSON["days"] as! [Any]).count == 2, "rollback prune and writes preserve both buckets")
        rollbackClock.date = date("2024-03-11T00:02:00Z")
        let clockRestored = DictationActivityStore(url: rollbackURL, now: { rollbackClock.date }, timeZone: utc)
        clockRestored.record(futureBucketEntry)
        check(clockRestored.days.count == 2 && clockRestored.days.reduce(0, { $0 + $1.dictations }) == 2, "forward clock restores prior totals and receipts without duplication")

        // Corruption, invalid dates and schema mismatches reset coverage conservatively.
        let validJSON = try json(boundedURL)
        var variants: [[String: Any]] = []
        var invalid = validJSON
        invalid["version"] = 999
        variants.append(invalid)
        invalid = validJSON
        invalid["timeZoneIdentifier"] = "Invalid/Zone"
        variants.append(invalid)
        invalid = validJSON
        invalid["trackingStartedAt"] = date("2024-03-12T00:00:00Z").timeIntervalSince1970
        variants.append(invalid)
        for day in ["2024-02-30", "2099-01-01"] {
            invalid = validJSON
            invalid["days"] = [["day": day, "characters": 1, "dictations": 1, "duration": 2]]
            variants.append(invalid)
        }
        for field in ["characters", "dictations", "duration"] {
            invalid = validJSON
            var day = (invalid["days"] as! [[String: Any]])[0]
            day[field] = -1
            invalid["days"] = [day]
            variants.append(invalid)
        }
        invalid = validJSON
        invalid["days"] = (invalid["days"] as! [Any]) + (invalid["days"] as! [Any])
        variants.append(invalid)
        for (index, variant) in variants.enumerated() {
            let corruptURL = file("corrupt-\(index)")
            try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try writeJSON(variant, to: corruptURL)
            let corrupt = DictationActivityStore(url: corruptURL, now: { clock.date }, timeZone: utc)
            check(corrupt.errorMessage != nil, "invalid file variant \(index) reported")
            check(corrupt.days.isEmpty && corrupt.trackingStartedAt == clock.date, "invalid file variant \(index) conservatively starts anew")
        }
        let brokenURL = file("malformed")
        try FileManager.default.createDirectory(at: brokenURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: brokenURL)
        let broken = DictationActivityStore(url: brokenURL, now: { clock.date }, timeZone: utc)
        check(broken.days.isEmpty && broken.errorMessage != nil, "malformed file does not resurrect history")
        let brokenRestart = DictationActivityStore(url: brokenURL, now: { clock.date }, timeZone: utc)
        check(brokenRestart.days.isEmpty, "conservative recovery marker persists")

        // Deterministic I/O failure: turn the parent directory into a file (no permissions tricks).
        let failedURL = file("io-failure")
        let failing = DictationActivityStore(url: failedURL, now: { clock.date }, timeZone: utc)
        failing.record(entry(clock.date))
        let saved = try Data(contentsOf: failedURL)
        let failedParent = failedURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: failedParent)
        try Data("not a directory".utf8).write(to: failedParent)
        clock.date = clock.date.addingTimeInterval(1)
        check(!failing.reset(), "failed reset reported instead of pretending success")
        check(failing.days.first?.dictations == 1 && failing.errorMessage != nil, "failed reset preserves displayed totals")
        let retry = entry(clock.date)
        failing.record(retry)
        check(failing.days.first?.dictations == 2 && failing.errorMessage != nil, "failed record kept in memory with durable-save warning")
        try FileManager.default.removeItem(at: failedParent)
        try FileManager.default.createDirectory(at: failedParent, withIntermediateDirectories: true)
        try saved.write(to: failedURL)
        failing.record(retry)
        check(failing.days.first?.dictations == 2 && failing.errorMessage == nil, "later write retries pending count without duplicate")
        check(DictationActivityStore(url: failedURL, now: { clock.date }, timeZone: utc).days.first?.dictations == 2, "retry durable across restart")
        print("Activity tests passed (\(assertions) assertions; offline temporary synthetic data only)")
    }
}
