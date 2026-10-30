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
            Text("Confirmed spellings help recognition and AI polish when enabled. They are hints, not forced replacements.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Dictionary section", selection: $section) {
                Text("My terms (\(settings.dictionaryTerms.count))").tag(Section.terms)
                Text("Review (\(review.pendingCandidates.count))").tag(Section.review)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if section == .terms { termsContent }
            else { reviewContent }

            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel("Dictionary status: \(message)")
            }
        }
        .sheet(item: $editor) { item in
            DictionaryTermEditor(original: item.original, settings: settings) { saved in
                message = item.original == nil ? "Added “\(saved)” to My terms." : "Saved “\(saved)”."
            }
        }
        .alert("Delete this term?", isPresented: Binding(
            get: { termToDelete != nil }, set: { if !$0 { termToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { termToDelete = nil }
            Button("Delete", role: .destructive) {
                if let term = termToDelete,
                   let updated = DictionaryTerms.replacing(term, with: nil, in: settings.dictionary) {
                    settings.dictionary = updated
                    message = "Deleted “\(term)”. History is unchanged."
                }
                termToDelete = nil
            }
        } message: {
            Text("“\(termToDelete ?? "")” will no longer be a dictionary hint. This does not delete history or dismiss review suggestions.")
        }
        .alert("Reset dismissed suggestions?", isPresented: $showResetDismissals) {
            Button("Cancel", role: .cancel) {}
            Button("Reset dismissals") { review.resetDismissals(); message = "Dismissed spellings can appear in Review again." }
        } message: {
            Text("Previously dismissed spellings may reappear from your scanned history. No terms will be added automatically.")
        }
    }

    private var termsContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Search terms", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: search) { _, _ in page = 0 }
                Button("Add term…") { editor = TermEditor(original: nil) }
            }
            List(visibleTerms, id: \.self) { term in
                HStack(spacing: 12) {
                    Text(term).font(.system(.body, design: .monospaced))
                        .textSelection(.enabled).lineLimit(2)
                        .help(term)
                    Spacer(minLength: 8)
                    Button { editor = TermEditor(original: term) } label: { Image(systemName: "pencil") }
                        .accessibilityLabel("Edit \(term)").help("Edit term")
                    Button { termToDelete = term } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Delete \(term)").help("Delete term")
                }
                .padding(.vertical, 5)
            }
            .listStyle(.inset)
            .overlay {
                if filteredTerms.isEmpty {
                    emptyState(title: search.isEmpty ? "Your spellings belong here" : "No matching terms",
                               detail: search.isEmpty ? "Add a name, project, or technical term, or confirm a suggestion in Review." : "Try another search or add a new term.",
                               symbol: "character.book.closed")
                }
            }
            HStack {
                Text("Capitalization is preserved. Existing terms are never shortened.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if filteredTerms.count > pageSize {
                    Button { page = max(0, currentPage - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(currentPage == 0).accessibilityLabel("Previous terms page")
                    Text("\(currentPage + 1) / \((filteredTerms.count + pageSize - 1) / pageSize)")
                        .font(.caption).monospacedDigit()
                    Button { page = currentPage + 1 } label: { Image(systemName: "chevron.right") }
                        .disabled((currentPage + 1) * pageSize >= filteredTerms.count)
                        .accessibilityLabel("Next terms page")
                }
            }
        }
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Toggle("Automatically find suggestions in local history", isOn: $settings.dictionaryReviewEnabled)
                    .toggleStyle(.switch).controlSize(.small)
                Text("Off by default. Scanning compares raw dictation with saved AI-polished text on this Mac; it sends nothing and makes no AI requests. AI edits can be wrong—accept only spellings you recognize.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(review.isScanning ? "Scanning…" : "Scan history") {
                        review.scanHistory()
                        message = ""
                    }
                    .disabled(review.isScanning)
                    if review.isScanning { ProgressView().controlSize(.small) }
                    Spacer()
                    if review.dismissedCount > 0 {
                        Button("Reset dismissed (\(review.dismissedCount))…") { showResetDismissals = true }
                            .font(.caption)
                    }
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))

            List(review.pendingCandidates) { candidate in
                DictionaryCandidateRow(candidate: candidate, accept: {
                    if review.accept(candidate) { message = "Added “\(candidate.term)” to My terms. No replacement rule was created." }
                }, dismiss: {
                    review.dismiss(candidate)
                    message = "Dismissed “\(candidate.term)”. It will stay hidden until you reset dismissals."
                })
            }
            .listStyle(.inset)
            .overlay {
                if review.pendingCandidates.isEmpty, !review.isScanning {
                    emptyState(title: review.hasScanned ? "No spellings to review" : "Your history stays unscanned",
                               detail: review.hasScanned ? "Only small spelling changes are suggested. You can always add a term yourself." : "Choose Scan history for a one-time local scan, or turn on automatic suggestions.",
                               symbol: "text.magnifyingglass")
                }
            }
            Text(review.hasScanned
                 ? "\(review.lastScanEntryCount) recent entries scanned · Up to 100 suggestions · Edits and translations excluded"
                 : "Scans up to 500 recent entries · Suggestions are never accepted automatically")
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
                Text("\(candidate.occurrenceCount) \(candidate.occurrenceCount == 1 ? "dictation" : "dictations")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                evidence(label: "Heard", text: candidate.correction.sourceSnippet)
                evidence(label: "Polished", text: candidate.correction.outputSnippet)
            }
            HStack {
                Text(candidate.date, format: .dateTime.month().day())
                    .font(.caption).foregroundStyle(.secondary)
                if !candidate.app.isEmpty {
                    Text("· \(candidate.app)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Dismiss", action: dismiss).help("Hide this spelling until dismissals are reset")
                Button("Accept", action: accept)
                    .help("Add this spelling to My terms, not a replacement rule")
                    .accessibilityLabel("Accept \(candidate.term) into My terms")
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
        guard let term = DictionaryTerms.validated(text) else { return "Enter one non-empty term, without line breaks." }
        if settings.dictionaryTerms.contains(term), term != original { return "This exact spelling is already in My terms." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(original == nil ? "Add a term" : "Edit term").font(.title2.weight(.semibold))
            Text("Use the spelling you want Talkless to recognize. Capitalization and spaces within the term are kept.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name, project, or technical term", text: $text)
                .textFieldStyle(.roundedBorder).focused($focused)
            if let validation { Text(validation).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(original == nil ? "Add term" : "Save changes") { save() }
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
