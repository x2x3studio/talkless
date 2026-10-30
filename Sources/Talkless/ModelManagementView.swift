import SwiftUI

/// Catalogue controls embedded in the Models settings form.
struct ModelManagementView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var manager = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @AppStorage("modelDownloadSourceChoice") private var sourceChoice = "huggingFace"
    @AppStorage("customModelDownloadSource") private var customSource = ""
    @State private var deletion: CatalogModel?
    @State private var deleting = false
    @State private var deletionError: String?
    @State private var actionError: String?

    private var controlsDisabled: Bool { controller.state != .idle || manager.isBusy }

    private var selectedSource: ModelDownloadSource? {
        switch sourceChoice {
        case "huggingFace": return .huggingFace
        case "hfMirror": return .hfMirror
        case "custom":
            guard let url = URL(string: customSource.trimmingCharacters(in: .whitespacesAndNewlines)),
                  ModelDownloadSource.isSecureURL(url), url.query == nil, url.fragment == nil,
                  !url.path.contains(".."), !url.path.contains("\\") else { return nil }
            return .custom(url)
        default: return .huggingFace
        }
    }

    var body: some View {
        Group {
            Section {
                HStack(spacing: 13) {
                    Image(systemName: "waveform")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(SettingsAppearance.accent)
                        .frame(width: 48, height: 48)
                        .background(SettingsAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 13))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.tr("Your voice. On your Mac."))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                        Text(L10n.tr("Download once. Transcribe locally with Qwen3 ASR."))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            Section(L10n.tr("Speech models")) {
                ForEach(manager.entries) { entry in
                    modelRow(entry)
                }
                if let error = manager.error, !manager.entries.contains(where: { $0.error == error }) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section(L10n.tr("Download source")) {
                Picker(L10n.tr("Source"), selection: $sourceChoice) {
                    ForEach(ModelCatalog.sources, id: \.title) { source in
                        Text(source.title).tag(source == .huggingFace ? "huggingFace" : "hfMirror")
                    }
                    Text(L10n.tr("Custom mirror…")).tag("custom")
                }
                .disabled(controlsDisabled)

                if sourceChoice == "hfMirror" {
                    Text(ModelCatalog.mirrorNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if sourceChoice == "custom" {
                    TextField(L10n.tr("HTTPS base URL"), text: $customSource, prompt: Text("https://your-mirror.example"))
                        .textFieldStyle(.roundedBorder)
                        .disabled(controlsDisabled)
                    Text(L10n.tr("A Hugging Face-compatible HTTPS mirror. Files are verified against the original model checksums."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !customSource.isEmpty, selectedSource == nil {
                        Text(L10n.tr("Enter an HTTPS URL without credentials, a query, or a fragment."))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } else {
                    Text(L10n.tr("Downloads come from mlx-community on Hugging Face, not Talkless."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(item: $deletion) { model in
                deletionSheet(model)
            }
            .alert(L10n.tr("Model operation failed"), isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            )) {
                Button(L10n.tr("OK"), role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
        }
    }

    private func isInUse(_ entry: ModelEntry) -> Bool {
        entry.phase == .installed && manager.activeModelID == entry.id &&
            settings.asrEngine == .qwen && !settings.useCustomQwenDirectory
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.model.name)
                    .font(.system(size: 14, weight: .semibold))
                if entry.model.isRecommended {
                    badge(L10n.tr("Recommended"), highlighted: false)
                }
                Spacer(minLength: 0)
                if isInUse(entry) {
                    badge(L10n.tr("In use"), highlighted: true)
                }
            }

            HStack(spacing: 6) {
                Text(L10n.format("%@ · MLX 4-bit", byteCount(entry.model.totalBytes)))
                Spacer()
                if let url = URL(string: "https://huggingface.co/\(entry.model.manifest.repository)") {
                    Link(destination: url) {
                        Label(L10n.tr("Model details"), systemImage: "arrow.up.right")
                    }
                    .help(L10n.format("View %@ on Hugging Face", entry.model.manifest.repository))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if entry.phase == .downloading || entry.phase == .paused {
                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(L10n.format("%@ download", entry.model.name))
                    .accessibilityValue(L10n.format("%@ of %@", byteCount(entry.downloadedBytes), byteCount(entry.totalBytes)))
            }

            HStack(spacing: 10) {
                if entry.phase == .checking || entry.phase == .verifying || entry.phase == .deleting {
                    ProgressView().controlSize(.small)
                }
                Text(isInUse(entry) ? (controller.modelPreparationStatus ?? statusText(entry)) : statusText(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                rowActions(entry)
                    .controlSize(.small)
            }

            if let error = entry.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .contain)
    }

    private func badge(_ title: String, highlighted: Bool) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(highlighted ? SettingsAppearance.accent : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                highlighted ? SettingsAppearance.accent.opacity(0.10) : Color.primary.opacity(0.05),
                in: Capsule()
            )
    }

    @ViewBuilder
    private func rowActions(_ entry: ModelEntry) -> some View {
        switch entry.phase {
        case .notInstalled:
            downloadButton(L10n.tr("Download"), entry: entry)
        case .paused:
            deleteButton(entry)
            downloadButton(L10n.tr("Resume"), entry: entry)
        case .failed:
            deleteButton(entry)
            downloadButton(L10n.tr("Retry"), entry: entry)
        case .downloading, .verifying:
            Button(L10n.tr("Cancel")) { manager.cancel() }
                .disabled(manager.operationModelID != entry.id)
                .help(L10n.tr("Pause this download and keep its progress"))
                .accessibilityLabel(L10n.format("Cancel %@ download", entry.model.name))
        case .installed:
            deleteButton(entry)
            if !isInUse(entry) {
                Button(L10n.tr("Use")) { select(entry) }
                    .buttonStyle(.borderedProminent)
                    .disabled(controlsDisabled)
                    .accessibilityLabel(L10n.format("Use %@", entry.model.name))
            }
        case .checking, .deleting:
            EmptyView()
        }
    }

    private func downloadButton(_ title: String, entry: ModelEntry) -> some View {
        Button(title) {
            guard let source = selectedSource else { return }
            manager.install(modelID: entry.id, source: source)
        }
        .buttonStyle(.borderedProminent)
        .disabled(controlsDisabled || selectedSource == nil)
        .accessibilityLabel(L10n.format("%@ %@", title, entry.model.name))
    }

    private func deleteButton(_ entry: ModelEntry) -> some View {
        Button(L10n.tr("Delete…"), role: .destructive) {
            deletionError = nil
            deletion = entry.model
        }
            .disabled(controlsDisabled)
            .accessibilityLabel(L10n.format("Delete %@", entry.model.name))
    }

    private func select(_ entry: ModelEntry) {
        Task {
            do {
                try await manager.select(modelID: entry.id)
                settings.useCustomQwenDirectory = false
                settings.asrEngine = .qwen
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func deletionSheet(_ model: CatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.format("Delete %@?", model.name))
                .font(.title3.weight(.semibold))
            Text(L10n.tr("This removes the downloaded model files from this Mac. You can download them again at any time."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if manager.activeModelID == model.id, !settings.useCustomQwenDirectory {
                Text(L10n.tr("This is your selected model. Download it again or choose another model before dictating."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let deletionError {
                Text(deletionError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if deleting {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Deleting…")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.tr("Cancel"), role: .cancel) { deletion = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(deleting)
                Button(L10n.tr("Delete Model"), role: .destructive) {
                    deleting = true
                    deletionError = nil
                    Task {
                        defer { deleting = false }
                        do {
                            try await manager.delete(modelID: model.id)
                            deletion = nil
                        } catch {
                            deletionError = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(controlsDisabled || deleting)
            }
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled(deleting)
    }

    private func statusText(_ entry: ModelEntry) -> String {
        switch entry.phase {
        case .checking: L10n.tr("Checking downloaded files…")
        case .notInstalled: L10n.tr("Not downloaded")
        case .downloading: L10n.format("%@ of %@", byteCount(entry.downloadedBytes), byteCount(entry.totalBytes))
        case .verifying: L10n.tr("Verifying model files…")
        case .paused: L10n.format("Paused · %@ of %@", byteCount(entry.downloadedBytes), byteCount(entry.totalBytes))
        case .installed: L10n.tr("Downloaded")
        case .failed: L10n.tr("Download failed")
        case .deleting: L10n.tr("Deleting model files…")
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
