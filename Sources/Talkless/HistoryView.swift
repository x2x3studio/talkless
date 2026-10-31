import SwiftUI

/// Settings › History: daily activity, then searchable recent results grouped by day.
struct HistoryView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var history: HistoryStore
    private let activity: DictationActivityStore
    @State private var confirmClear = false
    @State private var search = ""
    @State private var filter = Filter.all

    enum Filter: Hashable, CaseIterable {
        case all, dictation, edit, translation

        var title: String {
            switch self {
            case .all: L10n.tr("All")
            case .dictation: L10n.tr("Dictation")
            case .edit: L10n.tr("Voice Edit")
            case .translation: L10n.tr("Translation")
            }
        }

        func includes(_ kind: HistoryEntry.Kind) -> Bool {
            switch self {
            case .all: true
            case .dictation: kind == .dictation
            case .edit: kind == .edit
            case .translation: kind == .translation
            }
        }
    }

    init(history: HistoryStore = .shared, activity: DictationActivityStore = .shared) {
        self.history = history
        self.activity = activity
    }

    private var filteredEntries: [HistoryEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        return history.entries.filter { entry in
            filter.includes(entry.kind) && (query.isEmpty
                || entry.output.localizedStandardContains(query) || entry.raw.localizedStandardContains(query)
                || entry.app.localizedStandardContains(query))
        }
    }

    /// Newest day first; entries keep their newest-first order within a day.
    private var days: [(day: Date, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(day: Date, entries: [HistoryEntry])] = []
        for entry in filteredEntries {
            let day = calendar.startOfDay(for: entry.date)
            if groups.last?.day == day { groups[groups.count - 1].entries.append(entry) }
            else { groups.append((day, [entry])) }
        }
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DictationActivityView(store: activity)
                Divider()
                header
                if history.entries.isEmpty {
                    emptyState(symbol: "clock", title: L10n.tr("No history yet"),
                               detail: L10n.tr("Your dictations, voice edits, and translations will appear here."))
                } else {
                    toolbar
                    if filteredEntries.isEmpty {
                        emptyState(symbol: "magnifyingglass", title: L10n.tr("No matching history"),
                                   detail: L10n.tr("Try another search or filter."))
                    } else {
                        LazyVStack(alignment: .leading, spacing: 18, pinnedViews: []) {
                            ForEach(days, id: \.day) { group in
                                daySection(group.day, entries: group.entries)
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .alert(L10n.tr("Clear saved history?"), isPresented: $confirmClear) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Clear history"), role: .destructive) { history.clear() }
        } message: {
            Text(L10n.tr("This deletes saved transcripts. Daily activity totals are kept separately; use Clear activity to remove those too."))
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.tr("Recent history")).font(.headline)
            Text(L10n.format("%d saved entries", history.entries.count))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(L10n.tr("Clear history…")) { confirmClear = true }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(history.entries.isEmpty)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.tr("Search history"), text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.tr("Clear search"))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
            Picker(L10n.tr("Show"), selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .id(localization.locale.identifier)
        }
    }

    private func daySection(_ day: Date, entries: [HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayTitle(day))
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { Divider().padding(.leading, 52) }
                    HistoryRow(entry: entry) { history.delete(entry) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return L10n.tr("Today") }
        if calendar.isDateInYesterday(day) { return L10n.tr("Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        let style = sameYear ? Date.FormatStyle.dateTime.month().day().weekday(.wide)
            : Date.FormatStyle.dateTime.year().month().day()
        return day.formatted(style.locale(L10n.locale))
    }

    private func emptyState(symbol: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }
}

private struct HistoryRow: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    let entry: HistoryEntry
    let delete: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))
                .accessibilityLabel(kindTitle)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.output).lineLimit(4).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.raw != entry.output {
                    Text(rawLabel + entry.raw)
                        .font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(kindTitle)
                    if !entry.app.isEmpty { Text("·"); Text(entry.app).lineLimit(1) }
                    Text("·")
                    Text(entry.date, format: .dateTime.hour().minute().locale(L10n.locale))
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Button {
                TextIO.copyToClipboard(entry.output)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(copied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .opacity(hovering || copied ? 1 : 0.45)
            .help(L10n.tr("Copy Result"))
            .accessibilityLabel(L10n.tr("Copy Result"))
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(hovering ? Color.primary.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.tr("Copy Result")) { TextIO.copyToClipboard(entry.output) }
            Button(L10n.tr("Copy Raw Transcript")) { TextIO.copyToClipboard(entry.raw) }
            Divider()
            Button(L10n.tr("Delete"), role: .destructive, action: delete)
        }
    }

    private var symbol: String {
        switch entry.kind {
        case .dictation: "mic.fill"
        case .edit: "pencil"
        case .translation: "character.bubble"
        }
    }

    private var tint: Color {
        switch entry.kind {
        case .dictation: .accentColor
        case .edit: .purple
        case .translation: .teal
        }
    }

    private var kindTitle: String {
        switch entry.kind {
        case .dictation: L10n.tr("Dictation")
        case .edit: L10n.tr("Voice Edit")
        case .translation: L10n.tr("Translation")
        }
    }

    /// What the raw text means differs by kind.
    private var rawLabel: String {
        switch entry.kind {
        case .dictation: L10n.tr("Heard: ")
        case .edit: L10n.tr("Instruction: ")
        case .translation: L10n.tr("Original: ")
        }
    }
}
