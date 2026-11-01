import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Every row reads "heard → written". Learned fixes come and go on their own; terms you add
/// stay until you delete them.
struct DictionaryView: View {
    @ObservedObject private var settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }
    @State private var search = ""
    @State private var editor: TermEditor?
    @State private var termToDelete: String?
    @State private var message = ""

    private struct TermEditor: Identifiable {
        let id = UUID()
        let original: String?
    }

    private func matches(_ values: [String]) -> Bool {
        search.isEmpty || values.contains { $0.localizedStandardContains(search) }
    }

    private var learned: [LearnedFix] {
        settings.learnedDictionary.fixes.filter(\.active)
            .filter { matches([$0.heard, $0.term]) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    private var pendingCount: Int { settings.learnedDictionary.fixes.filter { !$0.active }.count }

    private var manualTerms: [String] {
        let rules = settings.activeDictionaryReplacements
        return settings.dictionaryTerms.filter { term in
            matches([term] + DictionaryReplacements.rules(for: term, in: rules).map(\.heard))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Each entry turns what the recognizer heard into what you meant. It also helps recognition and AI polish get it right the first time."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("Learn from my dictations")).font(.body.weight(.medium))
                    Text(L10n.tr("When polish keeps fixing the same word, Talkless learns it. Fixes unused for 30 days retire on their own. Everything stays on this Mac."))
                        .settingsNote()
                }
                Spacer(minLength: 8)
                Toggle(L10n.tr("Learn from my dictations"), isOn: $settings.dictionaryLearningEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))

            HStack {
                TextField(L10n.tr("Search"), text: $search)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.tr("Add…")) { editor = TermEditor(original: nil) }
                Menu {
                    Button(L10n.tr("Import…"), action: importTerms)
                    Button(L10n.tr("Export…"), action: exportTerms).disabled(settings.dictionaryTerms.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.tr("More dictionary actions"))
            }

            List {
                if settings.dictionaryLearningEnabled, !learned.isEmpty {
                    Section(L10n.format("Learned automatically (%lld)", learned.count)) {
                        ForEach(learned) { fix in learnedRow(fix) }
                    }
                }
                if !manualTerms.isEmpty {
                    Section(L10n.format("Added by you (%lld)", manualTerms.count)) {
                        ForEach(manualTerms, id: \.self) { term in manualRow(term) }
                    }
                }
            }
            .listStyle(.inset)
            .overlay {
                if learned.isEmpty && manualTerms.isEmpty {
                    emptyState(title: search.isEmpty ? L10n.tr("Nothing learned yet") : L10n.tr("No matches"),
                               detail: search.isEmpty ? L10n.tr("Keep dictating with AI polish on, and words it keeps fixing show up here. You can also add one yourself.") : L10n.tr("Try another search or add a new entry."),
                               symbol: "character.book.closed")
                }
            }

            HStack {
                if settings.dictionaryLearningEnabled, pendingCount > 0 {
                    Text(L10n.format("Watching %lld more spellings until they repeat.", pendingCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !message.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel(L10n.format("Dictionary status: %@", message))
                }
            }
        }
        .sheet(item: $editor) { item in
            DictionaryTermEditor(original: item.original, settings: settings) { saved in
                message = item.original == nil ? L10n.format("Added “%@”.", saved) : L10n.format("Saved “%@”.", saved)
            }
        }
        .alert(L10n.tr("Delete this entry?"), isPresented: Binding(
            get: { termToDelete != nil }, set: { if !$0 { termToDelete = nil } }
        )) {
            Button(L10n.tr("Cancel"), role: .cancel) { termToDelete = nil }
            Button(L10n.tr("Delete"), role: .destructive) {
                if let term = termToDelete,
                   let updated = DictionaryTerms.replacing(term, with: nil, in: settings.dictionary) {
                    settings.dictionary = updated
                    settings.dictionaryReplacements = DictionaryReplacements.renaming(term, to: nil, in: settings.dictionaryReplacements)
                    message = L10n.format("Deleted “%@”. History is unchanged.", term)
                }
                termToDelete = nil
            }
        } message: {
            Text(L10n.format("“%@” and its fixes will be removed. History is unchanged.", termToDelete ?? ""))
        }
    }

    private func mapping(heard: [String], term: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if heard.isEmpty {
                Text(term).font(.system(.body, design: .monospaced).weight(.medium))
            } else {
                Text(heard.joined(separator: L10n.tr(", ")))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .strikethrough(true, color: .secondary.opacity(0.6))
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.tr("becomes"))
                Text(term).font(.system(.body, design: .monospaced).weight(.medium))
            }
        }
        .lineLimit(2)
        .textSelection(.enabled)
    }

    private func learnedRow(_ fix: LearnedFix) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                mapping(heard: [fix.heard], term: fix.term)
                Text(L10n.format("Seen %lld times · Fixed %lld times · Last used %@", fix.observations, fix.applied,
                                 fix.lastSeen.formatted(.relative(presentation: .named).locale(L10n.locale))))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button(L10n.tr("Keep")) {
                settings.keepLearnedFix(fix)
                message = L10n.format("“%@” moved to Added by you and will not retire.", fix.term)
            }
            .help(L10n.tr("Keep this fix permanently"))
            Button { settings.removeLearnedFix(fix)
                message = L10n.format("Removed. “%@” will not be learned again.", fix.heard)
            } label: { Image(systemName: "trash") }
                .accessibilityLabel(L10n.format("Delete %@", fix.heard))
                .help(L10n.tr("Delete and never learn this fix again"))
        }
        .padding(.vertical, 4)
    }

    private func manualRow(_ term: String) -> some View {
        let heard = DictionaryReplacements.rules(for: term, in: settings.activeDictionaryReplacements).map(\.heard)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                mapping(heard: heard, term: term)
                if heard.isEmpty {
                    Text(L10n.tr("Recognition hint only. Add how it is misheard to fix it every time."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button { editor = TermEditor(original: term) } label: { Image(systemName: "pencil") }
                .accessibilityLabel(L10n.format("Edit %@", term)).help(L10n.tr("Edit"))
            Button { termToDelete = term } label: { Image(systemName: "trash") }
                .accessibilityLabel(L10n.format("Delete %@", term)).help(L10n.tr("Delete"))
        }
        .padding(.vertical, 4)
    }

    /// Adds terms and fixes from a text file; existing entries are never deleted or changed.
    private func importTerms() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.message = L10n.tr("One term per line. Add heard spellings after “=”, separated by commas.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            message = L10n.tr("That file could not be read as UTF-8 text.")
            return
        }
        let merge = DictionaryTransfer.merge(text, into: settings.dictionary, rules: settings.dictionaryReplacements)
        settings.dictionary = merge.dictionary
        settings.dictionaryReplacements = merge.rules
        message = L10n.format("Imported %lld terms and %lld fixes. %lld entries skipped.",
                              merge.addedTerms, merge.addedFixes, merge.skipped)
    }

    private func exportTerms() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Talkless Dictionary.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = DictionaryTransfer.export(terms: settings.dictionaryTerms, rules: settings.activeDictionaryReplacements)
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            message = L10n.format("Exported %lld terms.", settings.dictionaryTerms.count)
        } catch {
            message = L10n.tr("The dictionary could not be exported.")
        }
    }

    private func emptyState(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 350)
        }
        .padding(24)
        .allowsHitTesting(false)
    }
}

struct DictionaryTermEditor: View {
    let original: String?
    @ObservedObject var settings: AppSettings
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var heardText: String
    @FocusState private var focused: Bool

    init(original: String?, settings: AppSettings, onSave: @escaping (String) -> Void) {
        self.original = original
        self.settings = settings
        self.onSave = onSave
        _text = State(initialValue: original ?? "")
        _heardText = State(initialValue: original.map {
            DictionaryReplacements.rules(for: $0, in: settings.activeDictionaryReplacements).map(\.heard).joined(separator: "\n")
        } ?? "")
    }

    private var heard: [String] { DictionaryReplacements.heardSpellings(in: heardText) }

    private var validation: String? {
        guard let term = DictionaryTerms.validated(text) else { return L10n.tr("Enter one non-empty term, without line breaks.") }
        if settings.dictionaryTerms.contains(term), term != original { return L10n.tr("This entry already exists.") }
        // Other terms' rules only; this term's existing rules are being replaced.
        let otherRules = settings.activeDictionaryReplacements.filter { $0.term != original && $0.term != term }
        let otherTerms = settings.dictionaryTerms.filter { $0 != original }
        for spelling in heard {
            if let problem = DictionaryReplacements.problem(heard: spelling, term: term, rules: otherRules, terms: otherTerms) { return problem }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? L10n.tr("Add an entry") : L10n.tr("Edit entry")).font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Heard as")).font(.callout.weight(.medium))
                TextField(L10n.tr("What recognition writes by mistake, one per line"), text: $heardText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
                Text(L10n.tr("Optional. Leave empty to use the entry only as a recognition hint. Latin words match whole words only."))
                    .settingsNote()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Write as")).font(.callout.weight(.medium))
                TextField(L10n.tr("The correct spelling, e.g. Talkless"), text: $text)
                    .textFieldStyle(.roundedBorder).focused($focused)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? L10n.tr("Add") : L10n.tr("Save changes")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }
        .padding(24).frame(width: 460)
        .onAppear { focused = true }
    }

    private func save() {
        guard let term = DictionaryTerms.validated(text), validation == nil else { return }
        let updated = original.map { DictionaryTerms.replacing($0, with: term, in: settings.dictionary) }
            ?? DictionaryTerms.adding(term, to: settings.dictionary)
        guard let updated else { return }
        settings.dictionary = updated
        var rules = settings.dictionaryReplacements
        if let original { rules = DictionaryReplacements.renaming(original, to: term, in: rules) }
        settings.dictionaryReplacements = DictionaryReplacements.setting(heard, for: term, in: rules)
        onSave(term)
        dismiss()
    }
}
