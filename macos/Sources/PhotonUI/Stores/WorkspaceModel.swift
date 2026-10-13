import Foundation
import Observation

@MainActor @Observable
public final class WorkspaceModel {
    public var persona: WorkspacePersona = .perform
    public internal(set) var template: WorkspaceTemplate = .perform
    public var selectedClipID: String?
    public var selectedLayerID: String?
    public var selectedSlotID: String?
    public var selectedColumn: Int?
    public var inspectorScope: InspectorScope = .clip
    public var isCommandPalettePresented = false
    public var integrationIssue: PanelIssue?
    public var performanceLocked = false
    public var mappingQuad = MappingQuad.identity
    public internal(set) var requestedBlackout: Bool?
    var blackoutRequest: UInt64 = 0
    public var isBlackedOut: Bool { requestedBlackout ?? master.value?.blackout ?? false }
    public internal(set) var selectedDeckID: String?

    public let library = PanelModel<LibrarySnapshot>(name: "Library")
    public let preview = PanelModel<PreviewSnapshot>(name: "Preview")
    public let masterPreview = PanelModel<PreviewSnapshot>(name: "Master preview")
    public let inspector = PanelModel<InspectorSnapshot>(name: "Inspector")
    public let outputs = PanelModel<OutputSnapshot>(name: "Outputs")
    public let transport = PanelModel<TransportSnapshot>(name: "Transport")
    public let telemetry = PanelModel<TelemetrySnapshot>(name: "Metrics")
    public let layers = PanelModel<LayerStackSnapshot>(name: "Layers")
    public let master = PanelModel<MasterSnapshot>(name: "Master")
    public let effects = PanelModel<EffectStackSnapshot>(name: "Effects")
    public let effectDefinitions: [EffectDefinition]
    /// Blend modes the renderer published. Empty in previews and unit checks,
    /// where the only offer-able mode is the default — a menu must never list
    /// a mode the composite cannot perform.
    public let blendModeOptions: [BlendModeOption]
    /// Every chain the renderer needs, not just the one the inspector shows.
    /// Maintained by `reloadRenderEffects()`; read by the engine surface.
    public internal(set) var renderEffects: [InspectorEffectScope: [InspectorEffect]] = [:]
    var renderEffectsRequest: UInt64 = 0
    /// Recent tap-tempo presses. Never read by the renderer.
    private var taps: [Date] = []

    // Values of controls the operator is moving right now, ahead of the
    // provider acknowledging them. See `WorkspaceModel+LiveControls.swift`
    // for why these exist — without them a fader only reaches the output
    // ~80 ms after the drag ends, which cannot be performed with.
    public internal(set) var liveClipOpacity: [String: Double] = [:]
    public internal(set) var liveLayerOpacity: [String: Double] = [:]
    public internal(set) var liveMasterOpacity: Double?
    var liveControlRequests: [LiveControl: UInt64] = [:]

    let provider: any WorkspaceProvider
    let commands: WorkspaceCommandQueue
    let controlRefresh = ControlSnapshotRefresh()
    let preferences = WorkspacePreferences()

    public init(provider: any WorkspaceProvider = PreviewWorkspaceProvider(),
                effectDefinitions: [EffectDefinition] = [],
                blendModeOptions: [BlendModeOption] = []) {
        self.provider = provider
        self.effectDefinitions = effectDefinitions
        self.blendModeOptions = blendModeOptions
        self.commands = WorkspaceCommandQueue(provider: provider)
        self.template = preferences.template(for: persona)
    }

    public func start() async {
        let tasks = [
            reloadLibrary(), reloadPreview(), reloadInspector(),
            reloadOutputs(), reloadTransport(), reloadTelemetry(),
            reloadLayers(), reloadMaster(),
            reloadMasterPreview(),
        ]
        for task in tasks { await task.value }
        reloadRenderEffects()
        if selectedClipID == nil { selectedClipID = library.value?.clips.first?.id }
    }

    public func selectClip(_ id: String) {
        selectedClipID = id
        selectedSlotID = nil
        inspectorScope = .clip
        reloadPreview()
        reloadInspector()
    }

    public func selectLayer(_ id: String) {
        selectedLayerID = id
        inspectorScope = .layer
    }

    @discardableResult public func reloadLibrary() -> Task<Void, Never> {
        let provider = provider
        return library.load { try await provider.library().validated() }
    }

    @discardableResult public func reloadPreview() -> Task<Void, Never> {
        let provider = provider, id = selectedClipID
        return preview.load { try await provider.preview(clipID: id).validated() }
    }

    @discardableResult public func reloadInspector() -> Task<Void, Never> {
        let provider = provider, id = selectedClipID
        return inspector.load { try await provider.inspector(clipID: id).validated() }
    }

    @discardableResult public func reloadOutputs() -> Task<Void, Never> {
        let provider = provider
        return outputs.load { try await provider.outputs().validated() }
    }

    @discardableResult public func reloadTransport() -> Task<Void, Never> {
        let provider = provider
        return transport.load { try await provider.transport().validated() }
    }

    @discardableResult public func reloadTelemetry() -> Task<Void, Never> {
        let provider = provider
        return telemetry.load { try await provider.telemetry().validated() }
    }

    /// The clip's own opacity fader. Multiplies with the layer's, Resolume-style.
    public func setOpacity(_ value: Double, clipID: String) {
        // Busking: the engine must have this value now, not when the provider
        // round-trip and the 80 ms metadata debounce have both settled.
        let request = beginLiveControl(.clipOpacity(clipID))
        liveClipOpacity[clipID] = value
        commands.send(.setOpacity(clipID: clipID, value: value)) { [weak self] in
            self?.controlRefresh.schedule(.inspector) { [weak self] in
                guard self?.selectedClipID == clipID else { return }
                self?.reloadInspector()
            }
            // The layer stack carries the active clip's opacity, so the
            // acknowledged value has to come back through it. The override
            // above is what the renderer reads until it does.
            self?.controlRefresh.schedule(.layers) { [weak self] in
                self?.endLiveControl(.clipOpacity(clipID), request, after: self?.reloadLayers()) {
                    $0.liveClipOpacity[clipID] = nil
                }
            }
        } failed: { [weak self] issue in
            guard let self else { return }
            // A rejected value must snap back to what the provider actually
            // holds. Leaving the optimistic one on screen would show a fader
            // position the composite is not using.
            self.endLiveControl(.clipOpacity(clipID), request) { $0.liveClipOpacity[clipID] = nil }
            guard self.selectedClipID == clipID else { return }
            self.inspector.report(issue)
        }
    }

    /// The layer's blend mode — `LayerState.blend` in the engine.
    ///
    /// `mode` is the engine's `BlendMode` raw value. Callers get it from
    /// ``blendModeOptions``; nothing in the UI invents one.
    public func setLayerBlendMode(_ mode: Int32, layerID: String) {
        commands.send(.setLayerBlendMode(layerID: layerID, value: mode)) { [weak self] in
            self?.reloadLayers()
        } failed: { [weak self] issue in
            self?.layers.report(issue)
        }
    }

    public func togglePlayback() {
        guard !transport.phase.isLoading, let state = transport.value else { return }
        commands.send(.setPlaying(!state.isPlaying)) { [weak self] in
            self?.reloadTransport()
        } failed: { [weak self] issue in self?.transport.report(issue) }
    }

    /// Project tempo. Reaches `PhotonEngine.bpm`, which every BPM-synced clip
    /// reads in the same frame.
    public func setBPM(_ value: Double) {
        commands.send(.setBPM(value)) { [weak self] in
            self?.reloadTransport()
        } failed: { [weak self] issue in self?.transport.report(issue) }
    }

    /// Tap tempo.
    ///
    /// Averages the intervals between recent taps and commits the result as the
    /// tempo. Deliberately small: `photon-core`'s `clock.rs` owns the real
    /// thing — separable tempo and phase, slewed correction, outlier rejection
    /// — and this must not grow into a second copy of it. When the core session
    /// is wired this routes there instead and this arithmetic is deleted.
    ///
    /// A gap longer than ``tapTimeout`` starts a new count rather than
    /// averaging across it, because two taps either side of a pause describe a
    /// tempo nobody played.
    public func tapTempo(at now: Date = Date()) {
        if let last = taps.last, now.timeIntervalSince(last) > Self.tapTimeout { taps.removeAll() }
        taps.append(now)
        if taps.count > Self.tapWindow { taps.removeFirst(taps.count - Self.tapWindow) }
        // One tap only marks a start; an interval needs two.
        guard taps.count >= 2, let first = taps.first, let last = taps.last else { return }
        let average = last.timeIntervalSince(first) / Double(taps.count - 1)
        guard average > 0 else { return }
        let candidate = 60.0 / average
        // Out-of-range taps are dropped rather than clamped: clamping would
        // show 300 BPM for a stray double-tap and read as a working tap.
        guard (20...300).contains(candidate) else { return }
        setBPM((candidate * 10).rounded() / 10)
    }

    /// How many taps the average spans.
    private static let tapWindow = 4
    /// Longer than this between taps and the count restarts.
    private static let tapTimeout: TimeInterval = 2
}
