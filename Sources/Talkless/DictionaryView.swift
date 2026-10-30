import SwiftUI

/// A two-stage dictionary: only My terms supplies recognition/polish hints.
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
        settings.dictionaryTerms.filter { search.isEmpty || $0.localizedStandardContains(search) }
    }
    private var currentPage: Int { min(page, max(0, (filteredTerms.count - 1) / pageSize)) }
    private var visibleTerms: [String] {
        Array(filteredTerms.dropFirst(currentPage * pageSize).prefix(pageSize))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.tr("Confirmed spellings help recognition and AI polish when enabled. They are hints, not forced replacements."))
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
                    message = L10n.format("Deleted “%@”. History is unchanged.", term)
                }
                termToDelete = nil
            }
        } message: {
            Text(L10n.format("“%@” will no longer be a dictionary hint. This does not delete history or dismiss review suggestions.", termToDelete ?? ""))
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
            }
            List(visibleTerms, id: \.self) { term in
                HStack(spacing: 12) {
                    Text(term).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).lineLimit(2)
                        .help(term)
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
                DictionaryCandidateRow(candidate: candidate, accept: {
                    if review.accept(candidate) { message = L10n.format("Added “%@” to My terms. No replacement rule was created.", candidate.term) }
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
    let accept: () -> Void
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
    @FocusState private var focused: Bool

    init(original: String?, settings: AppSettings, onSave: @escaping (String) -> Void) {
        self.original = original
        self.settings = settings
        self.onSave = onSave
        _text = State(initialValue: original ?? "")
    }

    private var validation: String? {
        guard let term = DictionaryTerms.validated(text) else { return L10n.tr("Enter one non-empty term, without line breaks.") }
        if settings.dictionaryTerms.contains(term), term != original { return L10n.tr("This exact spelling is already in My terms.") }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? L10n.tr("Add a term") : L10n.tr("Edit term")).font(.title2.weight(.semibold))
            Text(L10n.tr("Use the spelling you want Talkless to recognize. Capitalization and spaces within the term are kept."))
                .font(.callout).foregroundStyle(.secondary)
            TextField(L10n.tr("Name, project, or technical term"), text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
            if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? L10n.tr("Add term") : L10n.tr("Save changes")) { save() }
                    .keyboardShortcut(.defaultAction).disabled(validation != nil)
            }
        }
        .padding(24).frame(width: 420)
        .onAppear { focused = true }
    }

    private func save() {
        guard let term = DictionaryTerms.validated(text), validation == nil else { return }
        let updated = original.map { DictionaryTerms.replacing($0, with: term, in: settings.dictionary) }
            ?? DictionaryTerms.adding(term, to: settings.dictionary)
        guard let updated else { return }
        settings.dictionary = updated
        onSave(term)
        dismiss()
    }
}
