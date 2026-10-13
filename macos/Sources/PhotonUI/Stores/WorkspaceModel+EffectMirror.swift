import Foundation

extension WorkspaceModel {
    /// Adds an effect to a chain, the way a drop from the browser means it.
    ///
    /// The scope is made visible first. A chain the operator cannot see is
    /// indistinguishable from a drop that did nothing, and this is the exact
    /// failure being fixed — so a drop on a layer row selects that layer.
    public func addEffect(definitionID: Int32, scope: InspectorEffectScope) {
        guard effectDefinitions.contains(where: { $0.id == definitionID }) else { return }
        switch scope {
        case let .layer(id) where currentEffectScope != scope:
            selectLayer(id)
        case let .clip(id) where currentEffectScope != scope:
            selectClip(id)
        default:
            break
        }
        changeEffect(.addEffect(scope: scope, definitionID: definitionID), scope: scope)
    }

    /// Re-reads the chains the renderer needs, as opposed to the single chain
    /// the inspector happens to be showing.
    ///
    /// The inspector's `effects` panel holds one scope at a time, because that
    /// is all a panel can display. The compositor needs every live layer's
    /// chain at once, so it gets its own mirror rather than the inspector's.
    ///
    /// `after` exists because a trigger changes which clip is live, and the
    /// clip's chain can only be fetched once the new layer stack has landed.
    @discardableResult
    public func reloadRenderEffects(after: Task<Void, Never>? = nil) -> Task<Void, Never> {
        renderEffectsRequest &+= 1
        let request = renderEffectsRequest
        let provider = provider
        return Task { @MainActor [weak self] in
            await after?.value
            guard let self, self.renderEffectsRequest == request else { return }
            let scopes: [InspectorEffectScope] = (self.layers.value?.layers ?? []).flatMap { layer in
                [.layer(layer.id)] + (layer.activeClipID.map { [InspectorEffectScope.clip($0)] } ?? [])
            }
            var resolved: [InspectorEffectScope: [InspectorEffect]] = [:]
            for scope in scopes {
                // A scope the provider rejects is simply absent from the mirror.
                // One unavailable chain must not blank out the others.
                guard let snapshot = try? await provider.effects(scope: scope).validated() else { continue }
                if !snapshot.effects.isEmpty { resolved[scope] = snapshot.effects }
            }
            guard self.renderEffectsRequest == request else { return }
            self.renderEffects = resolved
        }
    }

    /// The chain the engine must run for one layer, in render order.
    ///
    /// Clip effects first, then the layer's own — Resolume's order, and the
    /// order the hybrid compositor materialises a layer in anyway: the clip is
    /// the source, the layer is what the stack composites.
    public func renderChain(layerID: String, activeClipID: String?) -> [InspectorEffect] {
        let clip = activeClipID.flatMap { renderEffects[.clip($0)] } ?? []
        return clip + (renderEffects[.layer(layerID)] ?? [])
    }
}
