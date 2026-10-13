extension WorkspaceModel {
    public var currentEffectScope: InspectorEffectScope? {
        switch inspectorScope {
        case .composition: .composition
        case .layer: selectedLayerID.map { .layer($0) }
        case .clip: (selectedClipID ?? inspector.value?.clip.id).map { .clip($0) }
        case .group, .column: nil
        }
    }

    @discardableResult public func reloadEffects(scope: InspectorEffectScope) -> Task<Void, Never> {
        let provider = provider
        return effects.load { try await provider.effects(scope: scope).validated() }
    }

    public func changeEffect(_ action: WorkspaceAction, scope: InspectorEffectScope) {
        commands.send(action) { [weak self] in
            self?.reloadRenderEffects()
            guard self?.currentEffectScope == scope else { return }
            self?.reloadEffects(scope: scope)
        } failed: { [weak self] issue in
            guard self?.currentEffectScope == scope else { return }
            self?.effects.report(issue)
        }
    }
}
