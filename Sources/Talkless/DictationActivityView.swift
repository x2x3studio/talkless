import SwiftUI

/// Fixed thresholds keep a day's color stable when the visible range changes.
enum DictationActivityMetric: String, CaseIterable, Identifiable {
    case characters, dictations, minutes

    var id: Self { self }
    var title: String {
        switch self {
        case .characters: "Characters"
        case .dictations: "Dictations"
        case .minutes: "Minutes"
        }
    }
    var explanation: String {
        switch self {
        case .characters: "Characters in final dictation output, not words or tokens."
        case .dictations: "Completed dictations. Edits and translations are not included."
        case .minutes: "Recorded audio time for completed dictations."
        }
    }
    var legendLabels: [String] {
        switch self {
        case .characters: ["0", "1–99", "100–499", "500–1,999", "2,000+"]
        case .dictations: ["0", "1–4", "5–14", "15–29", "30+"]
        case .minutes: ["0", "<1", "1–<5", "5–<15", "15+"]
        }
    }
    func value(in day: DictationActivityDay) -> Double {
        switch self {
        case .characters: Double(day.characters)
        case .dictations: Double(day.dictations)
        case .minutes: day.duration / 60
        }
    }
    func bucket(for value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let thresholds: [Double]
        switch self {
        case .characters: thresholds = [100, 500, 2_000]
        case .dictations: thresholds = [5, 15, 30]
        case .minutes: thresholds = [1, 5, 15]
        }
        return 1 + thresholds.filter { value >= $0 }.count
    }
}

struct DictationActivityCell: Identifiable {
    enum Coverage: String {
        case unknown = "Not recorded"
        case partial = "Since start"
        case tracked = "Tracked"
        case today = "So far today"
        case future = "Future"
    }

    let date: Date
    let day: String
    let total: DictationActivityDay?
    let coverage: Coverage
    var id: String { day }

    func formatted(_ metric: DictationActivityMetric) -> String {
        guard let total else { return "—" }
        let value: String
        switch metric {
        case .characters: value = total.characters.formatted()
        case .dictations: value = total.dictations.formatted()
        case .minutes:
            value = total.duration > 0 && total.duration < 6
                ? "<0.1" : (total.duration / 60).formatted(.number.precision(.fractionLength(1)))
        }
        return value
    }

    var readout: String {
        guard let total else {
            return coverage == .future ? "\(day) · Future date" : "\(day) · Not recorded — tracking had not started"
        }
        let seconds = total.duration.formatted(.number.precision(.fractionLength(0...2)))
        let status = coverage == .partial ? " · Since tracking began"
            : coverage == .today ? " · So far today" : ""
        return "\(day) · \(total.characters.formatted()) characters · \(total.dictations.formatted()) dictations · \(seconds) seconds\(status)"
    }
}

/// Calendar arithmetic, never seconds-per-day, keeps civil dates aligned across DST.
enum DictationActivityLayout {
    static func calendar(timeZoneIdentifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", locale: Locale(identifier: "en_US_POSIX"),
                      parts.year!, parts.month!, parts.day!)
    }

    static func cells(weeks: Int, now: Date, calendar: Calendar,
                      days: [DictationActivityDay], trackingStartedAt: Date) -> [DictationActivityCell] {
        guard weeks > 0 && weeks <= 52 else { return [] }
        let today = calendar.startOfDay(for: now)
        let sunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: today), to: today)!
        let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: sunday)!
        let trackingDay = dayKey(trackingStartedAt, calendar: calendar)
        let totals = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        return (0..<(weeks * 7)).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let key = dayKey(date, calendar: calendar)
            if date > today {
                return DictationActivityCell(date: date, day: key, total: nil, coverage: .future)
            }
            if key < trackingDay {
                return DictationActivityCell(date: date, day: key, total: nil, coverage: .unknown)
            }
            let total = totals[key] ?? DictationActivityDay(day: key, characters: 0, dictations: 0, duration: 0)
            let coverage: DictationActivityCell.Coverage = key == trackingDay && trackingStartedAt > date
                ? .partial : date == today ? .today : .tracked
            return DictationActivityCell(date: date, day: key, total: total, coverage: coverage)
        }
    }

    static func monthLabel(week: Int, cells: [DictationActivityCell], calendar: Calendar) -> String? {
        let start = week * 7
        guard start < cells.count else { return nil }
        let dates = cells[start..<min(start + 7, cells.count)].map(\.date)
        // Avoid colliding month labels when the range begins in a month's final week.
        if week == 0, let first = dates.first, calendar.component(.day, from: first) > 21 { return nil }
        guard let date = week == 0 ? dates.first : dates.first(where: { calendar.component(.day, from: $0) == 1 })
        else { return nil }
        // The final column cannot hold a month label; the explicit date range still names its dates.
        guard week == 0 || start + 7 < cells.count else { return nil }
        return date.formatted(Date.FormatStyle(locale: Locale(identifier: "en_US"),
                                               calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated))
    }
}

private enum ActivityPalette {
    // Ordinal validator: monotone lightness, adjacent delta L >= .06, one hue,
    // and nearest-surface step >= 2:1, on these exact surfaces in both modes.
    static let lightRamp: [UInt32] = [0x86b6ef, 0x3987e5, 0x1c5cab, 0x0d366b]
    static let darkRamp: [UInt32] = [0x184f95, 0x3987e5, 0x86b6ef, 0xcde2fb]
    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    static func surface(_ dark: Bool) -> Color { color(dark ? 0x1a1a19 : 0xfcfcfb) }
    static func fill(bucket: Int, dark: Bool) -> Color {
        bucket == 0 ? color(dark ? 0x383835 : 0xe9e9e5)
            : color((dark ? darkRamp : lightRamp)[min(4, max(1, bucket)) - 1])
    }
}

/// Density, rather than a second hue, supplies an ordered accessibility channel.
private struct ActivityTexture: Shape {
    var bucket: Int
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let spacing = CGFloat(11 - min(4, max(1, bucket)) * 2)
        for offset in stride(from: -rect.height, through: rect.width, by: spacing) {
            path.move(to: CGPoint(x: offset, y: rect.height))
            path.addLine(to: CGPoint(x: offset + rect.height, y: 0))
        }
        return path
    }
}

@MainActor
struct DictationActivityView: View {
    @ObservedObject private var store: DictationActivityStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @State private var weeks: Int
    @State private var metric: DictationActivityMetric = .characters
    @State private var showsTable: Bool
    @State private var selection: String?
    @State private var hoveredDay: String?
    @FocusState private var focusedDay: String?
    @State private var confirmsReset = false
    @State private var resetFailed = false
    @State private var showsInfo = false
    private let referenceDate: Date?
    private let useTexture: Bool
    private let cellPitch: CGFloat = 16

    init(store: DictationActivityStore = .shared, referenceDate: Date? = nil,
         initialWeeks: Int = 26, initiallyShowsTable: Bool = false, useTexture: Bool = false) {
        self.store = store
        self.referenceDate = referenceDate
        self.useTexture = useTexture
        _weeks = State(initialValue: [13, 26, 52].contains(initialWeeks) ? initialWeeks : 26)
        _showsTable = State(initialValue: initiallyShowsTable)
    }

    private var dark: Bool { colorScheme == .dark }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = referenceDate ?? context.date
            let calendar = DictationActivityLayout.calendar(timeZoneIdentifier: store.timeZoneIdentifier)
            let cells = DictationActivityLayout.cells(weeks: weeks, now: now, calendar: calendar,
                                                       days: store.days, trackingStartedAt: store.trackingStartedAt)
            content(cells: cells, calendar: calendar, now: now)
        }
        .confirmationDialog("Clear daily activity?", isPresented: $confirmsReset, titleVisibility: .visible) {
            Button("Clear activity", role: .destructive) {
                resetFailed = !store.reset()
                if !resetFailed { selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently clears daily totals and starts a new tracking baseline. Transcript history is not deleted.")
        }
        .alert("Activity could not be cleared", isPresented: $resetFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your existing totals were kept. Check available disk space and try again.")
        }
    }

    private func content(cells: [DictationActivityCell], calendar: Calendar, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 12) {
                Text("Activity")
                    .font(.system(size: 20, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Date range", selection: $weeks) {
                    Text("Last 3 months").tag(13)
                    Text("Last 6 months").tag(26)
                    Text("Last year").tag(52)
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                Menu {
                    Button(showsTable ? "Show calendar" : "Show daily table") { showsTable.toggle() }
                    Button("About these statistics") { showsInfo = true }
                    Divider()
                    Button("Clear activity…", role: .destructive) { confirmsReset = true }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Activity options")
                .popover(isPresented: $showsInfo) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("About activity").font(.headline)
                        Text("Counts completed dictation only. Characters are final text, not words or tokens. Edits and translations are excluded.")
                        Text("Tracking began \(store.trackingStartedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, calendar: calendar, timeZone: calendar.timeZone))). Earlier days were not recorded. The first day and today may be partial.")
                        Text("Dates use \(store.timeZoneIdentifier). Totals stay on this Mac and contain no transcript text. Clearing history does not clear activity.")
                    }
                    .font(.callout)
                    .padding(18)
                    .frame(width: 310)
                }
            }
            summary(cells: cells)
            VStack(alignment: .leading, spacing: 12) {
                if showsTable {
                    activityTable(cells: cells)
                } else {
                    heatmap(cells: cells, calendar: calendar)
                    HStack {
                        if let first = cells.first {
                            Text("\(dateLabel(first.date, calendar: calendar)) – \(dateLabel(now, calendar: calendar, includeYear: true))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        legend
                    }
                }
                Divider()
                let activeDay = hoveredDay ?? focusedDay ?? selection
                let activeCell = cells.first(where: { $0.day == activeDay })
                    ?? cells.last(where: { $0.coverage != .future })
                dayDetails(activeCell, calendar: calendar, now: now)
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .background(ActivityPalette.surface(dark), in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: weeks) { _, _ in hoveredDay = nil; focusedDay = nil }
        .onChange(of: showsTable) { _, _ in hoveredDay = nil; focusedDay = nil }
    }

    private func summary(cells: [DictationActivityCell]) -> some View {
        let totals = cells.compactMap(\.total)
        let characters = totals.reduce(0.0) { $0 + Double($1.characters) }
        let dictations = totals.reduce(0.0) { $0 + Double($1.dictations) }
        let minutes = totals.reduce(0.0) { $0 + $1.duration / 60 }
        let activeDays = totals.filter { $0.dictations > 0 }.count
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 0) {
                summaryMetric(.characters, value: characters.formatted(.number.precision(.fractionLength(0))), label: "Characters")
                summaryMetric(.dictations, value: dictations.formatted(.number.precision(.fractionLength(0))), label: "Dictations")
                summaryMetric(.minutes, value: durationLabel(minutes), label: "Recorded time")
            }
            Text("\(activeDays) active \(activeDays == 1 ? "day" : "days") in this period")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryMetric(_ item: DictationActivityMetric, value: String, label: String) -> some View {
        Button { metric = item } label: {
            VStack(alignment: .leading, spacing: 7) {
                Text(value)
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                HStack(spacing: 5) {
                    Text(label).font(.system(size: 11))
                    if metric == item {
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                }
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show daily \(item.title.lowercased())")
        .accessibilityLabel("\(label): \(value). Show in calendar.")
        .accessibilityAddTraits(metric == item ? .isSelected : [])
    }

    private func durationLabel(_ minutes: Double) -> String {
        if minutes >= 60 {
            return "\((minutes / 60).rounded(.down).formatted(.number.precision(.fractionLength(0))))h \(minutes.truncatingRemainder(dividingBy: 60).rounded(.down).formatted(.number.precision(.fractionLength(0))))m"
        }
        if minutes > 0 && minutes < 1 { return "<1m" }
        return "\(Int(minutes))m"
    }

    private func dateLabel(_ date: Date, calendar: Calendar, includeYear: Bool = false) -> String {
        let style = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        return date.formatted(includeYear ? style.year() : style)
    }

    private func dayDetails(_ cell: DictationActivityCell?, calendar: Calendar, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let cell {
                Text(calendar.isDate(cell.date, inSameDayAs: now) ? "Today" : dateLabel(cell.date, calendar: calendar))
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 8)
                if let total = cell.total {
                    Text("\(total.characters.formatted()) characters · \(total.dictations) \(total.dictations == 1 ? "dictation" : "dictations") · \(durationLabel(total.duration / 60))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not recorded").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected day")
        .accessibilityValue(cell?.readout ?? "No activity data")
    }

    private func heatmap(cells: [DictationActivityCell], calendar: Calendar) -> some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 20)
                    ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, label in
                        Text(label).font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: 12, height: cellPitch)
                    }
                }.accessibilityHidden(true)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(0..<weeks, id: \.self) { week in
                        VStack(spacing: 0) {
                            Text(DictationActivityLayout.monthLabel(week: week, cells: cells, calendar: calendar) ?? "")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                                .fixedSize().frame(width: cellPitch, height: 20, alignment: .leading)
                                .accessibilityHidden(true)
                            ForEach(cells[(week * 7)..<(week * 7 + 7)]) { cell in
                                dayButton(cell, cells: cells)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 3)
        }
        .defaultScrollAnchor(.trailing)
        .defaultScrollAnchor(.leading, for: .alignment)
        .accessibilityLabel("Daily \(metric.title.lowercased()) calendar, Sunday through Saturday")
    }

    private func dayButton(_ cell: DictationActivityCell, cells: [DictationActivityCell]) -> some View {
        Button { selection = cell.day } label: {
            swatch(bucket: cell.total.map { metric.bucket(for: metric.value(in: $0)) }, future: cell.coverage == .future)
                .overlay {
                    if selection == cell.day || hoveredDay == cell.day || focusedDay == cell.day {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary, lineWidth: 1.5)
                    }
                }
                .padding(1)
                .frame(width: cellPitch, height: cellPitch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(cell.coverage == .future)
        .focused($focusedDay, equals: cell.day)
        .onHover { inside in hoveredDay = inside ? cell.day : (hoveredDay == cell.day ? nil : hoveredDay) }
        .onMoveCommand { direction in
            guard let index = cells.firstIndex(where: { $0.day == cell.day }) else { return }
            let delta: Int
            switch direction {
            case .left: delta = -7
            case .right: delta = 7
            case .up: delta = -1
            case .down: delta = 1
            default: return
            }
            let target = index + delta
            if cells.indices.contains(target), cells[target].coverage != .future { focusedDay = cells[target].day }
        }
        .help(cell.readout)
        .accessibilityLabel(cell.readout)
        .accessibilityAddTraits(selection == cell.day ? .isSelected : [])
    }

    private func swatch(bucket: Int?, future: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(bucket.map { ActivityPalette.fill(bucket: $0, dark: dark) } ?? ActivityPalette.surface(dark))
            .overlay {
                if bucket == nil && !future {
                    // A small neutral dash distinguishes unknown coverage from a measured zero.
                    Capsule().fill(Color.secondary.opacity(0.65)).frame(width: 5, height: 1)
                } else if let bucket, bucket > 0, differentiateWithoutColor || useTexture {
                    ActivityTexture(bucket: bucket)
                        .stroke(dark && bucket >= 3 || !dark && bucket <= 1 ? Color.black.opacity(0.55) : Color.white.opacity(0.7), lineWidth: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
            }
            .frame(width: 14, height: 14)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { bucket in
                swatch(bucket: bucket)
                    .help(metric == .minutes && bucket == 1 ? "More than 0 and less than 1 minute per day" : "\(metric.legendLabels[bucket]) \(metric.title.lowercased()) per day")
            }
            Text("More").padding(.leading, 2)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(metric.title) per day. Not recorded; \(metric.legendLabels.joined(separator: "; ")).")
    }

    private func activityTable(cells: [DictationActivityCell]) -> some View {
        Table(Array(cells.reversed()), selection: $selection) {
            TableColumn("Date") { cell in Text(cell.day) }.width(82)
            TableColumn("Characters") { cell in Text(cell.formatted(.characters)).frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 68, ideal: 74)
            TableColumn("Dictations") { cell in Text(cell.formatted(.dictations)).frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 60, ideal: 66)
            TableColumn("Minutes") { cell in Text(cell.formatted(.minutes)).frame(maxWidth: .infinity, alignment: .trailing) }
                .width(min: 56, ideal: 60)
            TableColumn("Coverage") { cell in Text(cell.coverage.rawValue).foregroundStyle(.secondary) }
                .width(min: 86, ideal: 98)
        }
        .font(.caption)
        .monospacedDigit()
        .frame(height: 230)
        .accessibilityLabel("Daily activity table. Not recorded and future values are not zero. Since start means the first day of tracking.")
    }
}
