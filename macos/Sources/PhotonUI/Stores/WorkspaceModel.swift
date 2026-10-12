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

    let provider: any WorkspaceProvider
    let commands: WorkspaceCommandQueue
    let controlRefresh = ControlSnapshotRefresh()
    let preferences = WorkspacePreferences()

    public init(provider: any WorkspaceProvider = PreviewWorkspaceProvider()) {
        self.provider = provider
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

    public func setOpacity(_ value: Double, clipID: String) {
        commands.send(.setOpacity(clipID: clipID, value: value)) { [weak self] in
            self?.controlRefresh.schedule(.inspector) { [weak self] in
                guard self?.selectedClipID == clipID else { return }
                self?.reloadInspector()
            }
        } failed: { [weak self] issue in
            guard self?.selectedClipID == clipID else { return }
            self?.inspector.report(issue)
        }
    }

    public func setBlendMode(_ mode: String, clipID: String) {
        commands.send(.setBlendMode(clipID: clipID, value: mode)) { [weak self] in
            self?.reloadInspector()
        } failed: { [weak self] issue in
            guard self?.selectedClipID == clipID else { return }
            self?.inspector.report(issue)
        }
    }

    public func togglePlayback() {
        guard !transport.phase.isLoading, let state = transport.value else { return }
        commands.send(.setPlaying(!state.isPlaying)) { [weak self] in
            self?.reloadTransport()
        } failed: { [weak self] issue in self?.transport.report(issue) }
    }
}
