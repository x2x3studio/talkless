import SwiftUI

/// The same native language menu is used in settings and the translation panel.
@MainActor
struct LanguagePickerView: View {
    let title: String
    @Binding var selection: TranslationLanguageSelection
    let preferences: TranslationLanguagePreferences
    var automaticLabel: String = L10n.tr("Auto")
    var allowCustom = false
    var onManageLanguages: (() -> Void)? = nil
    @ObservedObject private var localization = LocalizationSettings.shared
    @State private var showingCustomLanguage = false
    @State private var customDraft = ""

    private var commonLanguages: [TranslationLanguage] {
        TranslationLanguages.menuLanguages(preferences: preferences, selection: selection)
    }

    var body: some View {
        Menu {
            languageButton(.auto, label: automaticLabel)
            if case .custom = selection {
                languageButton(selection, label: selection.displayName)
            } else if allowCustom, let name = preferences.customTargetName, !name.isEmpty {
                languageButton(.custom(name), label: name)
            }
            Divider()
            ForEach(commonLanguages) { language in
                languageButton(.languageID(language.id), label: language.displayName)
            }
            let visible = Set(commonLanguages.map(\.id))
            Menu(L10n.tr("More languages")) {
                ForEach(TranslationLanguages.all.filter { !visible.contains($0.id) }) { language in
                    languageButton(.languageID(language.id), label: language.displayName)
                }
            }
            if allowCustom {
                Divider()
                Button(L10n.tr("Custom language…")) {
                    if case .custom(let name) = selection { customDraft = name }
                    else { customDraft = preferences.customTargetName ?? "" }
                    showingCustomLanguage = true
                }
            }
            if let onManageLanguages {
                Divider()
                Button(L10n.tr("Manage preferred languages…"), action: onManageLanguages)
            }
        } label: {
            Text(selection == .auto ? automaticLabel : selection.displayName)
                .lineLimit(1)
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection == .auto ? automaticLabel : selection.displayName)
        .sheet(isPresented: $showingCustomLanguage) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L10n.tr("Custom language"))
                    .font(.title2.weight(.semibold))
                TextField(L10n.tr("Language name"), text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                Text(L10n.tr("Enter a language or regional variant. Translation quality depends on your AI model."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button(L10n.tr("Cancel")) { showingCustomLanguage = false }
                        .keyboardShortcut(.cancelAction)
                    Button(L10n.tr("Save")) {
                        selection = .custom(customDraft.trimmingCharacters(in: .whitespacesAndNewlines))
                        showingCustomLanguage = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(customDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 380)
        }
    }

    private func languageButton(_ value: TranslationLanguageSelection, label: String) -> some View {
        Button { selection = value } label: {
            if selection == value {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
    }
}

/// Draft edits are intentionally local until Save; Cancel and dismissal never mutate preferences.
@MainActor
struct PreferredTranslationLanguagesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var localization = LocalizationSettings.shared
    @State private var selectedIDs: Set<String>
    @State private var search = ""
    private let onSave: ([String]) -> Void

    init(preferredLanguageIDs: [String], onSave: @escaping ([String]) -> Void) {
        _selectedIDs = State(initialValue: Set(preferredLanguageIDs))
        self.onSave = onSave
    }

    private var filteredLanguages: [TranslationLanguage] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return TranslationLanguages.all }
        return TranslationLanguages.all.filter {
            $0.displayName.localizedStandardContains(query)
                || $0.englishName.localizedStandardContains(query)
                || $0.id.localizedStandardContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.tr("Preferred languages"))
                    .font(.title2.weight(.semibold))
                Text(L10n.tr("Choose which languages appear first in translation menus. Other languages remain available under More languages."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField(L10n.tr("Search languages"), text: $search)
                .textFieldStyle(.roundedBorder)
            List {
                if filteredLanguages.isEmpty {
                    Text(L10n.tr("No matching languages. Try another name."))
                        .foregroundStyle(.secondary)
                }
                ForEach(filteredLanguages) { language in
                    Toggle(isOn: Binding(
                        get: { selectedIDs.contains(language.id) },
                        set: { enabled in
                            if enabled { selectedIDs.insert(language.id) }
                            else { selectedIDs.remove(language.id) }
                        }
                    )) {
                        Text(language.displayName)
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 3)
                }
            }
            .listStyle(.bordered)
            Text(L10n.tr("Your primary, secondary, and selected languages stay available even when unchecked. Translation quality depends on your AI model."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.tr("Restore defaults")) {
                    selectedIDs = Set(TranslationLanguages.commonLanguageIDs)
                }
                Spacer()
                Button(L10n.tr("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.tr("Save")) {
                    onSave(TranslationLanguages.all.map(\.id).filter { selectedIDs.contains($0) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480, height: 600)
    }
}
