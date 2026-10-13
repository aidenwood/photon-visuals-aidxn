import Foundation

/// Commands survive panel reloads. Snapshot requests can be cancelled independently.
@MainActor
final class WorkspaceCommandQueue {
    private struct Entry {
        let action: WorkspaceAction
        let completed: @MainActor () -> Void
        let failed: @MainActor (PanelIssue) -> Void
    }

    private let provider: any WorkspaceProvider
    private var pending: [Entry] = []
    private var worker: Task<Void, Never>?

    init(provider: any WorkspaceProvider) { self.provider = provider }

    func send(
        _ action: WorkspaceAction,
        completed: @escaping @MainActor () -> Void,
        failed: @escaping @MainActor (PanelIssue) -> Void
    ) {
        let entry = Entry(action: action, completed: completed, failed: failed)
        // Replace only an adjacent unsent value for the same continuous control.
        // Never coalesce across a trigger/play/blackout event or cancel accepted work.
        if let key = action.continuousControl, pending.last?.action.continuousControl == key {
            pending[pending.count - 1] = entry
        } else {
            guard pending.count < 128 else {
                failed(PanelIssue(title: "Controls are busy", message: "Wait for queued controls to finish."))
                return
            }
            pending.append(entry)
        }
        guard worker == nil else { return }
        worker = Task {
            while !pending.isEmpty {
                let entry = pending.removeFirst()
                do {
                    try await provider.perform(entry.action)
                    entry.completed()
                } catch {
                    entry.failed((error as? PanelIssue) ?? PanelIssue(
                        title: "Change unavailable", message: "The control change could not be applied."
                    ))
                }
            }
            worker = nil
        }
    }
}

private enum ContinuousControl: Equatable {
    case clipOpacity(String), layerOpacity(String), masterOpacity
    case effect(InspectorEffectScope, String, EffectParameter)
}

private extension WorkspaceAction {
    var continuousControl: ContinuousControl? {
        switch self {
        case let .setOpacity(id, _): .clipOpacity(id)
        case let .setLayerOpacity(id, _): .layerOpacity(id)
        case .setMasterOpacity: .masterOpacity
        case let .setEffectParameter(scope, id, parameter, _): .effect(scope, id, parameter)
        default: nil
        }
    }
}
