import AppKit
import SwiftUI

/// Provider-first API settings. Requests are started only by the two explicit action buttons.
@MainActor
struct AIServiceSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    @State private var remoteModels: [RemoteModel] = []
    @State private var manualModelEntry = false
    @State private var modelStatus: RequestStatus?
    @State private var connectionResult: ConnectionTestResult?
    @State private var testDetailsExpanded = false
    @State private var diagnosticsCopied = false
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
            Section(L10n.tr("Shared AI service")) {
                AIServiceStatusView(settings: settings)
            }

            Section(L10n.tr("API provider")) {
                Picker(L10n.tr("Provider"), selection: Binding(
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
                .id(localization.locale.identifier)
                .pickerStyle(.menu)
                .accessibilityLabel(L10n.tr("API provider"))

                protocolControl

                if provider == .custom {
                    TextField(L10n.tr("Base URL"), text: $settings.llmBaseURL,
                              prompt: Text("https://api.example.com/v1"))
                    Picker(L10n.tr("Authentication"), selection: $settings.llmAuthMode) {
                        ForEach(LLMAuthMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .id(localization.locale.identifier)
                }

                SecureField(L10n.tr("API key"), text: $settings.llmAPIKey)
                    .help(provider == .custom
                          ? L10n.tr("Stored in your Mac's Keychain. Localhost endpoints can use an empty key.")
                          : L10n.tr("Stored in your Mac's Keychain."))

                if let error = settings.llmCredentialSaveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                modelControls

                if provider == .openRouter {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.tr("Free router limits and availability vary. Other models may be paid."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        DisclosureGroup(L10n.tr("About OpenRouter free")) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L10n.tr("openrouter/free uses changing free models with no paid fallback. Requires your own OpenRouter key."))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 12) {
                                    Link(L10n.tr("Get an API key"), destination: URL(string: "https://openrouter.ai/settings/keys")!)
                                    Link(L10n.tr("About the free router"), destination: URL(string: "https://openrouter.ai/openrouter/free")!)
                                }
                            }
                            .font(.caption)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Button(fetching ? L10n.tr("Fetching…") : L10n.tr("Fetch Models")) { fetchModels() }
                            .disabled(fetching || testing || settings.llmBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help(L10n.tr("Fetch available models from this provider."))
                        if fetching { ProgressView().controlSize(.small) }
                        Button(testing ? L10n.tr("Testing…") : L10n.tr("Test Connection")) { testConnection() }
                            .disabled(testing || fetching || !settings.llmConfigured)
                            .help(L10n.tr("Send a short test prompt using the current provider and model."))
                        if testing { ProgressView().controlSize(.small) }
                    }
                    Text(L10n.tr("Runs only when clicked. Your provider may charge for tests."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let modelStatus { statusView(modelStatus) }
                if let connectionResult {
                    connectionReceipt(connectionResult)
                } else {
                    DisclosureGroup(L10n.tr("Test input")) {
                        testInputs
                    }
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
        .onChange(of: settings.llmThinkingMode) { _, _ in
            invalidateTest()
        }
        .onDisappear {
            invalidateEndpointRequests()
        }
    }

    @ViewBuilder
    private var protocolControl: some View {
        if provider == .openAI || provider == .custom {
            Picker(L10n.tr("Protocol"), selection: $settings.llmProtocol) {
                ForEach(provider.protocolOptions, id: \.self) { apiProtocol in
                    Text(apiProtocol.label).tag(apiProtocol)
                }
            }
            .id(localization.locale.identifier)
        } else {
            LabeledContent(L10n.tr("Protocol"), value: settings.llmProtocol.label)
        }
    }

    @ViewBuilder
    private var modelControls: some View {
        if !remoteModels.isEmpty {
            Picker(L10n.tr("Model"), selection: Binding(
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
                Text(L10n.tr("Enter model ID…")).tag(ModelSelection.manual)
            }
            .id(localization.locale.identifier)
        }

        if remoteModels.isEmpty || manualModelEntry || !remoteModels.contains(where: { $0.id == settings.llmModel }) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(L10n.tr("Model ID"), text: $settings.llmModel, prompt: Text(provider.modelPlaceholder))
                if remoteModels.isEmpty && modelStatus == nil {
                    Text(L10n.tr("Enter a model ID or fetch available models."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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

    private var testInputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            receiptText(L10n.tr("System input"), value: ConnectionTestResult.systemInput)
            receiptText(L10n.tr("Test input"), value: ConnectionTestResult.userInput)
        }
        .padding(.top, 6)
    }

    private func connectionReceipt(_ result: ConnectionTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(result.status, systemImage: result.isSuccess ? "checkmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(result.isSuccess ? Color.primary : Color.red)
                Spacer(minLength: 8)
                Text(result.durationText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))

            DisclosureGroup(L10n.tr("Test details"), isExpanded: $testDetailsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text(L10n.tr("Provider")).foregroundStyle(.secondary)
                            Text(result.provider)
                        }
                        GridRow {
                            Text(L10n.tr("Model")).foregroundStyle(.secondary)
                            Text(result.model).textSelection(.enabled)
                        }
                        GridRow {
                            Text(L10n.tr("Protocol")).foregroundStyle(.secondary)
                            Text(result.apiProtocol.label)
                        }
                    }
                    testInputs
                    Divider()
                    receiptText(L10n.tr(result.isSuccess ? "Response" : "Error"), value: result.output)
                    Button {
                        NSPasteboard.general.clearContents()
                        diagnosticsCopied = NSPasteboard.general.setString(result.diagnostics, forType: .string)
                    } label: {
                        Label(L10n.tr(diagnosticsCopied ? "Copied" : "Copy Diagnostics"), systemImage: "doc.on.doc")
                    }
                }
                .font(.caption)
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func receiptText(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    ? L10n.tr("No models were listed. Enter a model ID manually.")
                    : L10n.format("Fetched %d models. You can also enter a model ID manually.", models.count))
            } catch {
                guard !Task.isCancelled, fetchRequestID == requestID, endpointIdentity == identity else { return }
                let message = (error as? LLMClient.ClientError)?.localizedDescription
                    ?? LLMClient.ClientError.network.localizedDescription
                modelStatus = .failure(L10n.format("Could not fetch models: %@ You can enter a model ID manually.", message))
            }
            fetchRequestID = nil
            fetchTask = nil
        }
    }

    private func testConnection() {
        invalidateTest()
        let requestID = UUID()
        let identity = endpointIdentity
        let model = settings.llmModel
        let thinking = settings.llmThinkingMode
        let config = ConnectionTestResult.configuration(from: settings.llmConfig)
        testRequestID = requestID
        let started = ProcessInfo.processInfo.systemUptime
        testTask = Task { @MainActor in
            let result: Result<String, Error>
            do {
                // Only these fixed inputs: no dictation, selection, dictionary, or instructions.
                let response = try await LLMClient.complete(
                    system: ConnectionTestResult.systemInput,
                    user: ConnectionTestResult.userInput,
                    config: config
                )
                result = .success(response)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, testRequestID == requestID,
                  endpointIdentity == identity, settings.llmModel == model,
                  settings.llmThinkingMode == thinking else { return }
            connectionResult = ConnectionTestResult(
                provider: identity.provider, config: config,
                duration: ProcessInfo.processInfo.systemUptime - started, result: result
            )
            testDetailsExpanded = true
            testRequestID = nil
            testTask = nil
        }
    }

    private func invalidateTest() {
        testTask?.cancel()
        testTask = nil
        testRequestID = nil
        connectionResult = nil
        testDetailsExpanded = false
        diagnosticsCopied = false
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

/// Local configuration status, not proof of a successful network request.
/// Feature pages provide navigation without starting requests or changing feature toggles.
@MainActor
struct AIServiceStatusView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings
    private let onConfigureAI: (() -> Void)?

    init(settings: AppSettings = .shared, onConfigureAI: (() -> Void)? = nil) {
        self.settings = settings
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        let configured = settings.llmConfigured
        HStack(spacing: 10) {
            Image(systemName: configured ? "slider.horizontal.3" : "exclamationmark.circle")
                .foregroundStyle(configured ? Color.secondary : Color.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(configured ? L10n.tr("Configuration complete") : L10n.tr("Setup needed"))
                    .font(.body.weight(.medium))
                Text(configured
                     ? L10n.tr("Connection is not checked automatically.")
                     : L10n.tr("Check your provider, API key, and model."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let onConfigureAI {
                Button(L10n.tr("AI service…"), action: onConfigureAI)
                    .help(L10n.tr("Configure the shared provider and model, or test the connection."))
            }
        }
        .padding(.vertical, 4)
    }
}
