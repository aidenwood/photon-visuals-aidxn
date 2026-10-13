// Native adapters map generated engine types into these display snapshots.
// Implementations must honor cancellation and keep decode/IO off the main actor.
public enum WorkspaceAction: Sendable {
    case setOpacity(clipID: String, value: Double)
    case setBlendMode(clipID: String, value: String)
    case setPlaying(Bool)
    case triggerClip(clipID: String, layerID: String)
    case triggerColumn(column: Int, deckID: String?)
    case setLayerOpacity(layerID: String, value: Double)
    case setLayerBypass(layerID: String, value: Bool)
    case setLayerSolo(layerID: String, value: Bool)
    case setMasterOpacity(Double)
    case setBlackout(Bool)
    case addEffect(scope: InspectorEffectScope, definitionID: Int32)
    case removeEffect(scope: InspectorEffectScope, effectID: String)
    case setEffectEnabled(scope: InspectorEffectScope, effectID: String, enabled: Bool)
    case setEffectParameter(scope: InspectorEffectScope, effectID: String, parameter: EffectParameter, value: Double)
    case moveEffect(scope: InspectorEffectScope, effectID: String, beforeID: String?)
}

public protocol WorkspaceProvider: Sendable {
    func library() async throws -> LibrarySnapshot
    func preview(clipID: String?) async throws -> PreviewSnapshot
    func masterPreview() async throws -> PreviewSnapshot
    func inspector(clipID: String?) async throws -> InspectorSnapshot
    func outputs() async throws -> OutputSnapshot
    func transport() async throws -> TransportSnapshot
    func telemetry() async throws -> TelemetrySnapshot
    func layers(deckID: String?) async throws -> LayerStackSnapshot
    func master() async throws -> MasterSnapshot
    func effects(scope: InspectorEffectScope) async throws -> EffectStackSnapshot
    func perform(_ action: WorkspaceAction) async throws
}

public extension WorkspaceProvider {
    func effects(scope: InspectorEffectScope) async throws -> EffectStackSnapshot {
        EffectStackSnapshot(scope: scope, effects: [])
    }
    func layers() async throws -> LayerStackSnapshot { try await layers(deckID: nil) }
}
