import AppKit
import Foundation
import SwiftUI

// Compile only the activity store and view, never the history singleton or app settings.
struct HistoryEntry {
    enum Kind { case dictation, edit, translation }
    var id = UUID()
    var date: Date
    var kind: Kind = .dictation
    var app = "Synthetic test"
    var raw = ""
    var output: String
    var duration: TimeInterval
}

@main
struct ActivityViewTests {
    @MainActor static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func date(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
        let now = date("2026-10-28T19:00:00Z")
        let calendar = DictationActivityLayout.calendar(timeZoneIdentifier: "America/Los_Angeles")
        let todayKey = DictationActivityLayout.dayKey(now, calendar: calendar)
        check(todayKey == "2026-10-28", "Date labels use the persisted tracking zone")
        let sparse = [DictationActivityDay(day: "2026-10-26", characters: 42, dictations: 2, duration: 75)]
        for weeks in [13, 26, 52] {
            let cells = DictationActivityLayout.cells(weeks: weeks, now: now, calendar: calendar,
                                                       days: sparse, trackingStartedAt: date("2026-10-26T19:00:00Z"))
            check(cells.count == weeks * 7, "The range has exactly the requested number of week columns")
            check(Set(cells.map(\.day)).count == cells.count, "Every day appears exactly once")
            check(calendar.component(.weekday, from: cells.first!.date) == 1, "Columns begin on Sunday")
            check(cells.last!.day == "2026-10-31", "The final column includes the current week")
            check(cells.filter { $0.coverage == .future }.count == 3, "Future slots are separate from zero")
            check(cells.first!.coverage == .unknown && cells.first!.total == nil, "Missing history is unknown")
            let partial = cells.first { $0.day == "2026-10-26" }!
            check(partial.coverage == .partial && partial.formatted(.characters) == "42", "First day shows totals since tracking began")
            check(partial.readout.contains("Since tracking began") && partial.readout.contains("75 seconds"), "Readout carries exact values and caveat")
            let zero = cells.first { $0.day == "2026-10-27" }!
            check(zero.coverage == .tracked && zero.total?.characters == 0, "Only covered missing dates become zero")
            let today = cells.first { $0.day == todayKey }!
            check(today.coverage == .today && today.readout.contains("So far today"), "Today is never labeled a full day")
            check(cells.last!.formatted(.minutes) == "—", "Future dates are not fabricated zeros")
        }
        for boundary in ["2026-03-10T12:00:00Z", "2026-11-03T12:00:00Z"] {
            let cells = DictationActivityLayout.cells(weeks: 13, now: date(boundary), calendar: calendar,
                                                       days: [], trackingStartedAt: date("2025-01-01T00:00:00Z"))
            check(cells.count == 91 && Set(cells.map(\.day)).count == 91, "DST never duplicates or omits dates")
            for (a, b) in zip(cells, cells.dropFirst()) {
                check(calendar.dateComponents([.day], from: a.date, to: b.date).day == 1, "DST keeps consecutive civil days")
            }
            check(zip(cells, cells.dropFirst()).contains { $1.date.timeIntervalSince($0.date) != 86_400 },
                  "Fixture actually crosses a daylight-saving transition")
        }
        let leap = DictationActivityLayout.cells(weeks: 13, now: date("2024-03-01T20:00:00Z"), calendar: calendar,
                                                  days: [], trackingStartedAt: date("2024-01-01T00:00:00Z"))
        check(leap.contains { $0.day == "2024-02-29" }, "Leap day appears")
        let newYear = DictationActivityLayout.cells(weeks: 13, now: date("2027-01-02T20:00:00Z"), calendar: calendar,
                                                     days: [], trackingStartedAt: date("2026-01-01T00:00:00Z"))
        check(newYear.last?.day == "2027-01-02", "Weeks cross Gregorian year boundaries")
        for invalid in [0, -1, 53] {
            check(DictationActivityLayout.cells(weeks: invalid, now: now, calendar: calendar, days: [], trackingStartedAt: now).isEmpty,
                  "Invalid ranges do not allocate grids")
        }
        for (metric, values) in [
            (DictationActivityMetric.characters, [0.0, 1, 99, 100, 499, 500, 1999, 2000]),
            (.dictations, [0.0, 1, 4, 5, 14, 15, 29, 30]),
            (.minutes, [0.0, 0.01, 0.99, 1, 4.99, 5, 14.99, 15])
        ] {
            for (value, expected) in zip(values, [0, 1, 1, 2, 2, 3, 3, 4]) {
                check(metric.bucket(for: value) == expected, "Fixed bucket boundaries: \(metric), \(value)")
            }
            check(metric.legendLabels.count == 5, "Every numeric bucket has a legend label")
            check(metric.bucket(for: .nan) == 0 && metric.bucket(for: -1) == 0, "Invalid values do not index the palette")
        }
        let subMinute = DictationActivityCell(date: now, day: todayKey,
            total: DictationActivityDay(day: todayKey, characters: 1, dictations: 1, duration: 1), coverage: .today)
        check(subMinute.formatted(.minutes) == "<0.1", "Nonzero short recordings never round to zero minutes")

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-activity-view-\(UUID())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let emptyStore = DictationActivityStore(url: work.appendingPathComponent("empty.json"), now: { now }, timeZone: calendar.timeZone)
        final class Clock { var date: Date; init(_ date: Date) { self.date = date } }
        let denseClock = Clock(date("2025-10-29T19:00:00Z"))
        let sparseClock = Clock(date("2026-09-10T19:00:00Z"))
        let denseStore = DictationActivityStore(url: work.appendingPathComponent("dense.json"), now: { denseClock.date }, timeZone: calendar.timeZone)
        let sparseStore = DictationActivityStore(url: work.appendingPathComponent("sparse.json"), now: { sparseClock.date }, timeZone: calendar.timeZone)
        let allCells = DictationActivityLayout.cells(weeks: 52, now: now, calendar: calendar, days: [], trackingStartedAt: now)
        let entries = allCells.filter { $0.coverage != .future }.enumerated().flatMap { index, cell -> [HistoryEntry] in
            // Deterministic varied synthetic usage, with rest days independent of weekday.
            var seed = UInt64(index + 1) &* 2_654_435_761
            func next(_ upperBound: Int) -> Int {
                seed &+= 0x9E3779B97F4A7C15
                var value = seed
                value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
                value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
                return Int((value ^ (value >> 31)) % UInt64(upperBound))
            }
            guard next(13) != 0 else { return [] }
            let count = 1 + next(4)
            let length = [20, 90, 280, 850][next(4)]
            return (0..<count).map { _ in
                let characters = length + next(max(1, length / 2))
                return HistoryEntry(date: cell.date, output: String(repeating: "a", count: characters),
                                    duration: Double(characters) * 0.16 + Double(next(30)))
            }
        }
        for entry in entries where entry.date >= denseStore.trackingStartedAt {
            denseClock.date = entry.date
            denseStore.record(entry)
        }
        denseClock.date = now
        for entry in [
            HistoryEntry(date: date("2026-09-10T19:00:00Z"), output: String(repeating: "a", count: 620), duration: 125),
            HistoryEntry(date: date("2026-10-26T19:00:00Z"), output: "\u{4f60}\u{597d}\u{1f469}\u{200d}\u{1f4bb}", duration: 75)
        ] {
            sparseClock.date = entry.date
            sparseStore.record(entry)
        }
        sparseClock.date = now
        check(sparseStore.days.first { $0.day == "2026-10-26" }?.characters == 3, "Unicode output uses grapheme clusters")
        check(denseStore.days.count > 300, "Dense fixture exercises a year of marks")
        check(emptyStore.days.isEmpty, "Empty state has no fabricated demo entries")
        let initialDay = DictationActivityLayout.cells(weeks: 13, now: now, calendar: calendar,
            days: [], trackingStartedAt: emptyStore.trackingStartedAt).first { $0.day == todayKey }!
        check(initialDay.coverage == .partial && initialDay.total?.characters == 0, "Midday install shows zero only since tracking began")
        let ignoredLegacy = DictationActivityLayout.cells(weeks: 13, now: now, calendar: calendar,
            days: sparse, trackingStartedAt: now).first { $0.day == "2026-10-26" }!
        check(ignoredLegacy.coverage == .unknown && ignoredLegacy.total == nil, "Prebaseline values never become legacy history backfill")
        let completeStart = calendar.startOfDay(for: now)
        let midnight = DictationActivityLayout.cells(weeks: 13, now: now, calendar: calendar,
            days: [], trackingStartedAt: completeStart).first { $0.day == todayKey }!
        check(midnight.coverage == .today, "A midnight baseline tracks the whole current day so far")

        if let argument = CommandLine.arguments.dropFirst().first {
            let output = URL(fileURLWithPath: argument, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            for (name, store, scheme, weeks, table, texture) in [
                ("empty-light", emptyStore, ColorScheme.light, 26, false, false),
                ("sparse-light", sparseStore, .light, 26, false, false),
                ("dense-texture", denseStore, .dark, 26, false, true),
                ("year-light", denseStore, .light, 52, false, false),
                ("table-light", denseStore, .light, 26, true, false),
                ("dense-dark", denseStore, .dark, 26, false, false),
                ("dense-light", denseStore, .light, 26, false, false)
            ] {
                let root = DictationActivityView(store: store, referenceDate: now, initialWeeks: weeks, initiallyShowsTable: table, useTexture: texture)
                    .padding(20)
                    .frame(width: 588, alignment: .topLeading)
                    .background(scheme == .dark ? Color(.sRGB, white: 0.13, opacity: 1) : Color(.sRGB, white: 0.96, opacity: 1))
                    .environment(\.colorScheme, scheme)
                let hosting = NSHostingView(rootView: root)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 588, height: table ? 510 : 470),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.title = "Talkless Activity — Synthetic data · Local preview"
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = hosting
                window.orderFrontRegardless()
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.25))
                hosting.layoutSubtreeIfNeeded()
                let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = bitmap.representation(using: .png, properties: [:])!
                check(data.count > 8_000, "Native snapshot is not blank")
                try data.write(to: output.appendingPathComponent(name + ".png"))
                if CommandLine.arguments.contains("--live"), name == "dense-light" {
                    print("LIVE synthetic activity grid ready; PASS \(assertions) assertions")
                    app.activate(ignoringOtherApps: true)
                    app.run()
                }
                window.orderOut(nil)
            }
            print("Rendered native activity snapshots in \(output.path)")
        }
        print("PASS \(assertions) activity layout, coverage, fixed buckets, DST, Unicode, and synthetic fixture assertions")
    }
}
