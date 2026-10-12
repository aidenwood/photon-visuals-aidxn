import Foundation
import Observation
import OSLog

/// One independently recoverable panel. The latest request owns its result.
@MainActor @Observable
public final class PanelModel<Value: Sendable> {
    public private(set) var phase: PanelPhase = .idle
    public private(set) var value: Value?
    public let name: String

    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private let logger = Logger(subsystem: "com.aidxn.photon.preview", category: "panel")

    public init(name: String) { self.name = name }

    @discardableResult
    public func load(
        timeout: Duration = .seconds(10),
        using loader: @escaping @Sendable () async throws -> Value
    ) -> Task<Void, Never> {
        cancel()
        phase = .loading
        let request = generation

        let task = Task { [weak self] in
            do {
                let value = try await loader()
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.value = value
                self.phase = .ready
                self.finish()
            } catch {
                guard let self, self.generation == request else { return }
                if error is CancellationError {
                    self.phase = self.value == nil ? .idle : .ready
                } else {
                    self.logger.error("Panel \(self.name, privacy: .public) refresh failed")
                    self.phase = .failed((error as? PanelIssue) ?? PanelIssue(
                        title: "\(self.name) unavailable",
                        message: "This panel could not refresh. Try again."
                    ))
                }
                self.finish()
            }
        }
        operation = task
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, self.generation == request, self.phase == .loading else { return }
            self.generation &+= 1
            self.operation?.cancel()
            self.operation = nil
            self.phase = .failed(PanelIssue(
                title: "\(self.name) is taking too long",
                message: "The last available data is kept. Retry this panel when ready."
            ))
            self.logger.warning("Panel \(self.name, privacy: .public) timed out")
            self.deadline = nil
        }
        return task
    }

    public func cancel() {
        generation &+= 1
        operation?.cancel()
        deadline?.cancel()
        operation = nil
        deadline = nil
        if phase == .loading { phase = value == nil ? .idle : .ready }
    }

    private func finish() {
        deadline?.cancel()
        deadline = nil
        operation = nil
    }

    public func report(_ issue: PanelIssue) {
        cancel()
        phase = .failed(issue)
    }

    #if DEBUG
    public func simulateFailure() {
        cancel()
        phase = .failed(PanelIssue(
            title: "\(name) unavailable",
            message: "A preview failure was injected into this panel. Retry to restore it."
        ))
    }
    #endif
}
