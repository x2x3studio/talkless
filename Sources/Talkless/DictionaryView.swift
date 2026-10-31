import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A two-stage dictionary: only My terms supplies recognition/polish hints, and only explicit
/// "heard as" spellings on those terms are replaced automatically.
struct DictionaryView: View {
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var review: DictionaryReviewStore

    init(settings: AppSettings = .shared, review: DictionaryReviewStore = .shared) {
        self.settings = settings
        self.review = review
    }
    @State private var section = Section.terms
    @State private var search = ""
    @State private var page = 0
    @State private var editor: TermEditor?
    @State private var termToDelete: String?
    @State private var showResetDismissals = false
    @State private var message = ""
    private let pageSize = 50

    private enum Section: Hashable { case terms, review }
    private struct TermEditor: Identifiable {
        let id = UUID()
        let original: String?
    }

    private var filteredTerms: [String] {
        let rules = settings.activeDictionaryReplacements
        return settings.dictionaryTerms.filter { term in
            search.isEmpty || term.localizedStandardContains(search)
                || rules.contains { $0.term == term && $0.heard.localizedStandardContains(search) }
        }
    }
    private var currentPage: Int { min(page, max(0, (filteredTerms.count - 1) / pageSize)) }
    private var visibleTerms: [String] {
        Array(filteredTerms.dropFirst(currentPage * pageSize).prefix(pageSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("My terms help recognition and AI polish. Add how a term is often misheard, and Talkless fixes that spelling every time, even with AI polish off."))
                .font(.callout).foregroundStyle(.secondary)
            Picker(L10n.tr("Dictionary section"), selection: $section) {
                Text(L10n.format("My terms (%lld)", settings.dictionaryTerms.count)).tag(Section.terms)
                Text(L10n.format("Review (%lld)", review.pendingCandidates.count)).tag(Section.review)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .terms { termsContent }
            else { reviewContent }

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.format("Dictionary status: %@", message))
            }
        }
        .sheet(item: $editor) { item in
            DictionaryTermEditor(original: item.original, settings: settings) { saved in
                message = item.original == nil ? L10n.format("Added “%@” to My terms.", saved) : L10n.format("Saved “%@”.", saved)
            }
        }
        .alert(L10n.tr("Delete this term?"), isPresented: Binding(
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
            Text(L10n.format("“%@” will no longer be a dictionary hint, and its heard spellings will no longer be fixed. This does not delete history or dismiss review suggestions.", termToDelete ?? ""))
        }
        .alert(L10n.tr("Reset dismissed suggestions?"), isPresented: $showResetDismissals) {
            Button(L10n.tr("Cancel"), role: .cancel) {}
            Button(L10n.tr("Reset dismissals")) { review.resetDismissals(); message = L10n.tr("Dismissed spellings can appear in Review again.") }
        } message: {
            Text(L10n.tr("Previously dismissed spellings may reappear from your scanned history. No terms will be added automatically."))
        }
    }

    private var termsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.tr("Search terms"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: search) { _, _ in page = 0 }
                Button(L10n.tr("Add term…")) { editor = TermEditor(original: nil) }
                Menu {
                    Button(L10n.tr("Import…"), action: importTerms)
                    Button(L10n.tr("Export…"), action: exportTerms).disabled(settings.dictionaryTerms.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(L10n.tr("More dictionary actions"))
            }
            List(visibleTerms, id: \.self) { term in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(term).font(.system(.body, design: .monospaced))
                            .textSelection(.enabled).lineLimit(2)
                            .help(term)
                        let heard = DictionaryReplacements.rules(for: term, in: settings.activeDictionaryReplacements).map(\.heard)
                        if !heard.isEmpty {
                            Text(L10n.format("Fixes: %@", heard.joined(separator: L10n.tr(", "))))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Button { editor = TermEditor(original: term) } label: { Image(systemName: "pencil") }
                        .accessibilityLabel(L10n.format("Edit %@", term)).help(L10n.tr("Edit term"))
                    Button { termToDelete = term } label: { Image(systemName: "trash") }
                        .accessibilityLabel(L10n.format("Delete %@", term)).help(L10n.tr("Delete term"))
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .overlay {
                if filteredTerms.isEmpty {
                    emptyState(title: search.isEmpty ? L10n.tr("Your spellings belong here") : L10n.tr("No matching terms"),
                               detail: search.isEmpty ? L10n.tr("Add a name, project, or technical term, or confirm a suggestion in Review.") : L10n.tr("Try another search or add a new term."),
                               symbol: "character.book.closed")
                }
            }
            HStack {
                Text(L10n.tr("Capitalization is preserved. Existing terms are never shortened."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if filteredTerms.count > pageSize {
                    Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(currentPage == 0).accessibilityLabel(L10n.tr("Previous terms page"))
                    Text("\(currentPage + 1) / \((filteredTerms.count + pageSize - 1) / pageSize)")
                        .font(.caption).monospacedDigit()
                    Button { page = currentPage + 1 } label: { Image(systemName: "chevron.right") }
                        .disabled((currentPage + 1) * pageSize >= filteredTerms.count)
                        .accessibilityLabel(L10n.tr("Next terms page"))
                }
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(L10n.tr("Automatically find suggestions in local history"), isOn: $settings.dictionaryReviewEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Text(L10n.tr("Off by default. Scanning compares raw dictation with saved AI-polished text on this Mac; it sends nothing and makes no AI requests. AI edits can be wrong—accept only spellings you recognize."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(review.isScanning ? L10n.tr("Scanning…") : L10n.tr("Scan history")) {
                        review.scanHistory()
                        message = ""
                    }
                    .disabled(review.isScanning)
                    if review.isScanning { ProgressView().controlSize(.small) }
                    Spacer()
                    if review.dismissedCount > 0 {
                        Button(L10n.format("Reset dismissed (%lld)…", review.dismissedCount)) { showResetDismissals = true }
                            .font(.caption)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))

            List(review.pendingCandidates) { candidate in
                DictionaryCandidateRow(candidate: candidate, canAlwaysFix: alwaysFixProblem(candidate) == nil, accept: {
                    if review.accept(candidate) { message = L10n.format("Added “%@” to My terms. No replacement rule was created.", candidate.term) }
                }, alwaysFix: {
                    guard alwaysFixProblem(candidate) == nil, review.accept(candidate) else { return }
                    settings.dictionaryReplacements.append(DictionaryReplacement(heard: candidate.correction.source, term: candidate.term))
                    message = L10n.format("Added “%@”. “%@” will now be fixed automatically.", candidate.term, candidate.correction.source)
                }, dismiss: {
                    review.dismiss(candidate)
                    message = L10n.format("Dismissed “%@”. It will stay hidden until you reset dismissals.", candidate.term)
                })
            }
            .listStyle(.inset)
            .overlay {
                if review.pendingCandidates.isEmpty, !review.isScanning {
                    emptyState(title: review.hasScanned ? L10n.tr("No spellings to review") : L10n.tr("Your history stays unscanned"),
                               detail: review.hasScanned ? L10n.tr("Only small spelling changes are suggested. You can always add a term yourself.") : L10n.tr("Choose Scan history for a one-time local scan, or turn on automatic suggestions."),
                               symbol: "text.magnifyingglass")
                }
            }
            Text(review.hasScanned
                 ? L10n.format("%lld recent entries scanned · Up to 100 suggestions · Edits and translations excluded", review.lastScanEntryCount)
                 : L10n.tr("Scans up to 500 recent entries · Suggestions are never accepted automatically"))
                .font(.caption).foregroundStyle(.secondary)
        }
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

    /// Review evidence is a recorded mishearing, so it can become a fix in one step.
    private func alwaysFixProblem(_ candidate: DictionaryCandidate) -> String? {
        DictionaryReplacements.problem(heard: candidate.correction.source, term: candidate.term,
                                       rules: settings.activeDictionaryReplacements, terms: settings.dictionaryTerms)
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

private struct DictionaryCandidateRow: View {
    let candidate: DictionaryCandidate
    let canAlwaysFix: Bool
    let accept: () -> Void
    let alwaysFix: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.term).font(.system(.headline, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Text(L10n.format(candidate.occurrenceCount == 1 ? "%lld dictation" : "%lld dictations", candidate.occurrenceCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                evidence(label: L10n.tr("Heard"), text: candidate.correction.sourceSnippet)
                evidence(label: L10n.tr("Polished"), text: candidate.correction.outputSnippet)
            }
            HStack {
                Text(candidate.date, format: .dateTime.month().day().locale(L10n.locale))
                    .font(.caption).foregroundStyle(.secondary)
                if !candidate.app.isEmpty {
                    Text("· \(candidate.app)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(L10n.tr("Dismiss"), action: dismiss).help(L10n.tr("Hide this spelling until dismissals are reset"))
                Button(L10n.tr("Accept"), action: accept)
                    .help(L10n.tr("Add this spelling to My terms, not a replacement rule"))
                    .accessibilityLabel(L10n.format("Accept %@ into My terms", candidate.term))
                if canAlwaysFix {
                    Button(L10n.tr("Always fix"), action: alwaysFix)
                        .help(L10n.format("Add “%@” to My terms and always replace “%@” with it", candidate.term, candidate.correction.source))
                        .accessibilityLabel(L10n.format("Always fix %@ as %@", candidate.correction.source, candidate.term))
                }
            }
        }
        .padding(.vertical, 9)
    }

    private func evidence(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DictionaryTermEditor: View {
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
        if settings.dictionaryTerms.contains(term), term != original { return L10n.tr("This exact spelling is already in My terms.") }
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
            Text(original == nil ? L10n.tr("Add a term") : L10n.tr("Edit term")).font(.title2.weight(.semibold))
            Text(L10n.tr("Use the spelling you want Talkless to recognize. Capitalization and spaces within the term are kept."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L10n.tr("Name, project, or technical term"), text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Often heard as (optional)")).font(.callout.weight(.medium))
                TextField(L10n.tr("One per line, e.g. a wrong spelling you keep getting"), text: $heardText, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...5)
                Text(L10n.tr("These exact spellings are replaced with the term after recognition. Latin words match whole words only."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? L10n.tr("Add term") : L10n.tr("Save changes")) { save() }
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
