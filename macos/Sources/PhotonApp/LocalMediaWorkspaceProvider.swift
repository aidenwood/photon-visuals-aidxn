import PhotonUI

/// Real catalogue metadata with existing editor controls. Live playback remains
/// explicitly marked DEMO until Claude supplies the shared runtime adapter.
actor LocalMediaWorkspaceProvider: WorkspaceProvider {
    private let catalog: LocalMediaCatalog
    private var loading: Task<PreviewWorkspaceProvider, Error>?

    init(catalog: LocalMediaCatalog) { self.catalog = catalog }

    private func editor() async throws -> PreviewWorkspaceProvider {
        if let loading { return try await loading.value }
        let catalog = catalog
        let task = Task {
            try await PreviewWorkspaceProvider(latency: .zero, clips: catalog.clips(), deckTitle: "Local media",
                effectDefinitions: NativeEffectDefinitions.all,
                blendModeOptions: NativeBlendModes.all)
        }
        loading = task
        do { return try await task.value }
        catch { loading = nil; throw error }
    }

    func library() async throws -> LibrarySnapshot { try await editor().library() }
    func preview(clipID: String?) async throws -> PreviewSnapshot { try await editor().preview(clipID: clipID) }
    func masterPreview() async throws -> PreviewSnapshot { try await editor().masterPreview() }
    func inspector(clipID: String?) async throws -> InspectorSnapshot { try await editor().inspector(clipID: clipID) }
    func outputs() async throws -> OutputSnapshot { try await editor().outputs() }
    func transport() async throws -> TransportSnapshot { try await editor().transport() }
    // Measured by the live render surface, not by the editor fixture — the
    // fixture has no renderer and correctly reports every metric as unknown.
    func telemetry() async throws -> TelemetrySnapshot { LiveTelemetryBus.shared.current }
    func layers(deckID: String?) async throws -> LayerStackSnapshot { try await editor().layers(deckID: deckID) }
    func master() async throws -> MasterSnapshot { try await editor().master() }
    func effects(scope: InspectorEffectScope) async throws -> EffectStackSnapshot { try await editor().effects(scope: scope) }
    func perform(_ action: WorkspaceAction) async throws { try await editor().perform(action) }
}
