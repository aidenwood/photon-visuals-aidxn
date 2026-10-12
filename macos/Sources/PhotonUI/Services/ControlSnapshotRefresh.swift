import Foundation

/// Control acknowledgements need metadata reconciliation, not one read per drag event.
@MainActor
final class ControlSnapshotRefresh {
    enum Scope: Hashable { case inspector, layers, master }
    private var pending: [Scope: Task<Void, Never>] = [:]

    func schedule(_ scope: Scope, refresh: @escaping @MainActor () -> Void) {
        cancel(scope)
        pending[scope] = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
            } catch { return }
            self?.pending[scope] = nil
            refresh()
        }
    }

    func cancel(_ scope: Scope) {
        pending.removeValue(forKey: scope)?.cancel()
    }
}
