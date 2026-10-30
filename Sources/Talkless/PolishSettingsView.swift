import SwiftUI

/// Provider-first API settings. Requests are started only by the two explicit action buttons.
@MainActor
struct PolishSettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var remoteModels: [RemoteModel] = []
    @State private var manualModelEntry = false
    @State private var modelStatus: RequestStatus?
    @State private var connectionStatus: RequestStatus?
    @State private var fetchTask: Task<Void, Never>?
    @State private var testTask: Task<Void, Never>?
    @State private var fetchRequestID: UUID?
    @State private var testRequestID: UUID?

    private var provider: PolishProvider { settings.selectedPolishProvider }
    private var fetching: Bool { fetchRequestID != nil }
    private var testing: Bool { testRequestID != nil }

    /// Include credentials in equality, but never display or log this value.
    private struct EndpointIdentity: Equatable {
        let provider: PolishProvider
        let baseURL: String
        let apiKey: String
        let apiProtocol: LLMProtocol
        let authMode: LLMAuthMode
    }

    private var endpointIdentity: EndpointIdentity {
        EndpointIdentity(
            provider: provider,
            baseURL: settings.llmBaseURL,
            apiKey: settings.llmAPIKey,
            apiProtocol: settings.llmProtocol,
            authMode: settings.llmAuthMode
        )
    }

    private enum ModelSelection: Hashable {
        case remote(String)
        case manual
    }

    private enum RequestStatus {
        case success(String)
        case failure(String)

        var text: String {
            switch self {
            case .success(let text), .failure(let text): text
            }
        }

        var isError: Bool {
            if case .failure = self { return true }
            return false
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Polish dictation with AI", isOn: $settings.polishEnabled)
                Text("Remove fillers, resolve corrections, and add punctuation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("API provider") {
                Picker("Provider", selection: Binding(
                    get: { provider },
                    set: { newProvider in
                        invalidateEndpointRequests()
                        settings.selectPolishProvider(newProvider)
                    }
                )) {
                    ForEach(PolishProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("API provider")

                protocolControl

                if provider == .custom {
                    TextField("Base URL", text: $settings.llmBaseURL,
                              prompt: Text("https://api.example.com/v1"))
                    Picker("Authentication", selection: $settings.llmAuthMode) {
                        ForEach(LLMAuthMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                }

                SecureField("API key", text: $settings.llmAPIKey)
                    .help(provider == .custom
                          ? "Stored in your Mac's Keychain. Localhost endpoints can use an empty key."
                          : "Stored in your Mac's Keychain.")

                if let error = settings.llmCredentialSaveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                modelControls

                HStack(spacing: 10) {
                    Button(fetching ? "Fetching…" : "Fetch Models") { fetchModels() }
                        .disabled(fetching || testing || settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if fetching { ProgressView().controlSize(.small) }
                    Button(testing ? "Testing…" : "Test Connection") { testConnection() }
                        .disabled(testing || fetching || !settings.llmConfigured)
                    if testing { ProgressView().controlSize(.small) }
                }

                if let modelStatus { statusView(modelStatus) }
                if let connectionStatus { statusView(connectionStatus) }

                Text("Test Connection sends a fixed “Reply with OK” test, not your dictation, dictionary, or writing instructions. Your provider may charge for the request.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Talkless does not request extra thinking. Some models reason by default; choose a non-reasoning model for faster polish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Output") {
                Picker("Output language", selection: $settings.outputLanguage) {
                    ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
                }
                TextField("Translation target language", text: $settings.translateTarget)
                Text("AI polish sends transcripts, selected text, and writing instructions to your selected provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("Advanced") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional instructions")
                            .font(.body.weight(.medium))
                        TextEditor(text: $settings.customInstructions)
                            .font(.body)
                            .frame(minHeight: 70, idealHeight: 90)
                            .accessibilityLabel("Additional instructions")
                        Text("For example: Always use digits for numbers, or Do not use exclamation marks.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: endpointIdentity) { _, _ in
            invalidateEndpointRequests()
        }
        .onChange(of: settings.llmModel) { _, _ in
            invalidateTest()
        }
        .onDisappear {
            invalidateEndpointRequests()
        }
    }

    @ViewBuilder
    private var protocolControl: some View {
        if provider == .openAI || provider == .custom {
            Picker("Protocol", selection: $settings.llmProtocol) {
                ForEach(provider.protocolOptions, id: \.self) { apiProtocol in
                    Text(apiProtocol.label).tag(apiProtocol)
                }
            }
        } else {
            LabeledContent("Protocol", value: settings.llmProtocol.label)
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        if !remoteModels.isEmpty {
            Picker("Model", selection: Binding(
                get: {
                    if !manualModelEntry, remoteModels.contains(where: { $0.id == settings.llmModel }) {
                        return ModelSelection.remote(settings.llmModel)
                    }
                    return .manual
                },
                set: { selection in
                    switch selection {
                    case .remote(let id):
                        manualModelEntry = false
                        settings.llmModel = id
                    case .manual:
                        manualModelEntry = true
                    }
                }
            )) {
                ForEach(remoteModels) { model in
                    Text(modelTitle(model)).tag(ModelSelection.remote(model.id))
                }
                Divider()
                Text("Enter model ID…").tag(ModelSelection.manual)
            }
        }

        if remoteModels.isEmpty || manualModelEntry || !remoteModels.contains(where: { $0.id == settings.llmModel }) {
            TextField("Model ID", text: $settings.llmModel, prompt: Text(provider.modelPlaceholder))
        }

        if remoteModels.isEmpty && modelStatus == nil {
            Text("Fetch available models, or enter a model ID manually.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func modelTitle(_ model: RemoteModel) -> String {
        guard let name = model.displayName, !name.isEmpty, name != model.id else { return model.id }
        return "\(name) — \(model.id)"
    }

    private func statusView(_ status: RequestStatus) -> some View {
        Label(status.text, systemImage: status.isError ? "exclamationmark.circle" : "checkmark.circle")
            .font(.caption)
            .foregroundStyle(status.isError ? Color.red : Color.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fetchModels() {
        fetchTask?.cancel()
        let requestID = UUID()
        let identity = endpointIdentity
        let config = settings.llmConfig
        fetchRequestID = requestID
        modelStatus = nil
        fetchTask = Task { @MainActor in
            do {
                let models = try await LLMClient.fetchModels(config: config)
                guard !Task.isCancelled, fetchRequestID == requestID, endpointIdentity == identity else { return }
                remoteModels = models
                manualModelEntry = !models.contains(where: { $0.id == settings.llmModel })
                modelStatus = .success(models.isEmpty
                    ? "No models were listed. Enter a model ID manually."
                    : "Fetched \(models.count) models. You can also enter a model ID manually.")
            } catch {
                guard !Task.isCancelled, fetchRequestID == requestID, endpointIdentity == identity else { return }
                modelStatus = .failure("Could not fetch models: \(error.localizedDescription) You can enter a model ID manually.")
            }
            fetchRequestID = nil
            fetchTask = nil
        }
    }

    private func testConnection() {
        testTask?.cancel()
        let requestID = UUID()
        let identity = endpointIdentity
        let model = settings.llmModel
        var config = settings.llmConfig
        config.maxOutputTokens = 1024
        testRequestID = requestID
        connectionStatus = nil
        testTask = Task { @MainActor in
            do {
                // Never use Prompts, dictation, selected text, the dictionary, or custom instructions here.
                _ = try await LLMClient.complete(
                    system: "You are checking an API connection. Reply briefly.",
                    user: "Reply with OK.",
                    config: config
                )
                guard !Task.isCancelled, testRequestID == requestID,
                      endpointIdentity == identity, settings.llmModel == model else { return }
                connectionStatus = .success("Connection successful. The model returned a response.")
            } catch {
                guard !Task.isCancelled, testRequestID == requestID,
                      endpointIdentity == identity, settings.llmModel == model else { return }
                connectionStatus = .failure("Connection failed: \(error.localizedDescription)")
            }
            testRequestID = nil
            testTask = nil
        }
    }

    private func invalidateTest() {
        testTask?.cancel()
        testTask = nil
        testRequestID = nil
        connectionStatus = nil
    }

    private func invalidateEndpointRequests() {
        fetchTask?.cancel()
        fetchTask = nil
        fetchRequestID = nil
        remoteModels = []
        modelStatus = nil
        manualModelEntry = false
        invalidateTest()
    }
}
