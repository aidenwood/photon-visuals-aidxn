import Foundation
import PhotonUI

/// Covers the path a dragged effect actually takes: browser payload → model →
/// provider → the render mirror the engine surface reads.
///
/// The mirror is the part worth checking. The inspector's own `effects` panel
/// holds one scope and is visible by eye; the mirror is what decides whether a
/// drop reaches output, and a drop that only updated the inspector is exactly
/// the bug these cases exist to catch.
@MainActor
struct EffectDropTests {
    private static let definitions = [
        EffectDefinition(id: 0, name: "Levels", category: "Colour", parameterLabel: "Gamma"),
        EffectDefinition(id: 17, name: "Kaleidoscope", category: "Distort", parameterLabel: "Rotation"),
    ]

    func aDropOnALayerReachesTheChainTheRendererReads() async throws {
        let (model, layer) = await startedModel()
        model.addEffect(definitionID: 17, scope: .layer(layer.id))
        await settle(model)

        let chain = model.renderChain(layerID: layer.id, activeClipID: layer.activeClipID)
        try require(chain.map(\.definitionID) == [17])
        try require(chain.first?.enabled == true)
    }

    func aDropSelectsTheScopeItLandedIn() async throws {
        let (model, layer) = await startedModel()
        model.addEffect(definitionID: 0, scope: .layer(layer.id))
        await settle(model)

        try require(model.selectedLayerID == layer.id)
        try require(model.currentEffectScope == .layer(layer.id))
        try require(model.effects.value?.effects.count == 1)
    }

    func anEffectTheEngineNeverPublishedIsRefused() async throws {
        let (model, layer) = await startedModel()
        model.addEffect(definitionID: 999, scope: .layer(layer.id))
        await settle(model)

        try require(model.renderChain(layerID: layer.id, activeClipID: layer.activeClipID).isEmpty)
    }

    func clipEffectsRunBeforeTheLayersOwn() async throws {
        let (model, layer) = await startedModel()
        model.addEffect(definitionID: 17, scope: .layer(layer.id))
        await settle(model)
        // A clip chain only matters once something is launched on the layer.
        guard let slot = layer.slots.compactMap(\.clip).first else {
            throw CheckFailure(message: "The fixture layer has no clip to launch.")
        }
        model.triggerClip(slot.id, layerID: layer.id)
        await settle(model)

        guard let live = model.layers.value?.layers.first, let clipID = live.activeClipID else {
            throw CheckFailure(message: "No clip became active on the layer.")
        }
        model.addEffect(definitionID: 0, scope: .clip(clipID))
        await settle(model)

        // Clip chain first, then the layer's own — the engine applies them to
        // one texture, so the order here is the order the picture gets.
        try require(model.renderChain(layerID: live.id, activeClipID: clipID).map(\.definitionID) == [0, 17])
    }

    func removingTheLastEffectClearsTheRenderersChain() async throws {
        let (model, layer) = await startedModel()
        model.addEffect(definitionID: 0, scope: .layer(layer.id))
        await settle(model)
        guard let added = model.renderEffects[.layer(layer.id)]?.first?.id else {
            throw CheckFailure(message: "The added effect never reached the render mirror.")
        }

        model.changeEffect(.removeEffect(scope: .layer(layer.id), effectID: added), scope: .layer(layer.id))
        await settle(model)

        try require(model.renderChain(layerID: layer.id, activeClipID: layer.activeClipID).isEmpty)
    }

    private func startedModel() async -> (WorkspaceModel, LayerSnapshot) {
        let provider = PreviewWorkspaceProvider(latency: .zero, effectDefinitions: Self.definitions)
        let model = WorkspaceModel(provider: provider, effectDefinitions: Self.definitions)
        await model.start()
        return (model, model.layers.value!.layers.first!)
    }

    /// The mirror is refreshed by a command completion, so a check has to let
    /// the command queue drain rather than assert on the turn the drop happened.
    private func settle(_ model: WorkspaceModel) async {
        for _ in 0..<80 {
            try? await Task.sleep(for: .milliseconds(10))
            await model.reloadRenderEffects().value
        }
    }
}
