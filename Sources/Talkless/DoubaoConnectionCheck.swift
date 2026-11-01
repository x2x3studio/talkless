import Combine
import Foundation

/// Explicit, cancelable connection check. A receipt belongs to exactly one key/resource pair;
/// changing either or leaving Settings cancels it and discards late results.
@MainActor
final class DoubaoConnectionCheck: ObservableObject {
    enum Outcome: Equatable { case success, failure(String) }
    typealias Validator = @Sendable (DoubaoConfig) async throws -> Void
    @Published private(set) var isChecking = false
    @Published private(set) var outcome: Outcome?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let validate: Validator

    init(validate: @escaping Validator = { try await DoubaoTranscriptionSession.validateConnection(config: $0) }) {
        self.validate = validate
    }

    func start(_ config: DoubaoConfig) {
        guard !isChecking else { return }
        invalidate()
        guard config.isConfigured else { outcome = .failure(DoubaoError.configuration.localizedDescription); return }
        isChecking = true
        let token = generation, validate = self.validate
        task = Task { [weak self] in
            let result: Outcome
            do {
                try await validate(config)
                result = .success
            } catch {
                // Only app-owned errors may reach the UI; never provider responses or keys.
                result = .failure((error as? DoubaoError ?? .connection).localizedDescription)
            }
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.isChecking = false
            self.outcome = result
            self.task = nil
        }
    }

    func invalidate() {
        generation += 1
        task?.cancel()
        task = nil
        isChecking = false
        outcome = nil
    }
}
