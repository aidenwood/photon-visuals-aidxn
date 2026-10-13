import Foundation

extension PreviewWorkspaceProvider {
    public func effects(scope: InspectorEffectScope) async throws -> EffectStackSnapshot {
        try validateEffectScope(scope)
        return EffectStackSnapshot(scope: scope, effects: effectStacks[scope] ?? [], editable: !effectDefinitions.isEmpty)
    }

    func performEffect(_ action: WorkspaceAction) throws {
        switch action {
        case let .addEffect(scope, definitionID):
            try validateEffectScope(scope)
            guard effectDefinitions.contains(where: { $0.id == definitionID }) else { throw invalidEffect() }
            effectStacks[scope, default: []].append(InspectorEffect(id: UUID().uuidString, definitionID: definitionID))
        case let .removeEffect(scope, id):
            let index = try effectIndex(scope, id)
            effectStacks[scope]?.remove(at: index)
        case let .setEffectEnabled(scope, id, enabled):
            let index = try effectIndex(scope, id)
            effectStacks[scope]?[index].enabled = enabled
        case let .setEffectParameter(scope, id, parameter, value):
            guard value.isFinite, (0...1).contains(value) else { throw invalidEffect() }
            let index = try effectIndex(scope, id)
            if parameter == .amount { effectStacks[scope]?[index].amount = value }
            else { effectStacks[scope]?[index].parameter = value }
        case let .moveEffect(scope, id, beforeID):
            let index = try effectIndex(scope, id)
            guard beforeID != id else { return }
            if let beforeID { _ = try effectIndex(scope, beforeID) }
            guard var chain = effectStacks[scope] else { throw invalidEffect() }
            let effect = chain.remove(at: index)
            let destination = beforeID.flatMap { target in chain.firstIndex { $0.id == target } } ?? chain.count
            chain.insert(effect, at: destination)
            effectStacks[scope] = chain
        default: throw invalidEffect()
        }
    }

    private func validateEffectScope(_ scope: InspectorEffectScope) throws {
        switch scope {
        case .composition: break
        case .layer(let id): guard Self.layerIDs.contains(id) else { throw invalidEffect() }
        case .clip(let id): _ = try clip(id)
        }
    }
    private func effectIndex(_ scope: InspectorEffectScope, _ id: String) throws -> Int {
        try validateEffectScope(scope)
        guard let index = effectStacks[scope]?.firstIndex(where: { $0.id == id }) else { throw invalidEffect() }
        return index
    }
    private func invalidEffect() -> PanelIssue {
        PanelIssue(title: "Effect change rejected", message: "This effect or parameter is unavailable.")
    }
}
