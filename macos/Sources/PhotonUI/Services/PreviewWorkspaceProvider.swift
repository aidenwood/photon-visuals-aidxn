import Foundation

/// UI fixtures only: no media decoder, renderer, hardware output, or measured FPS.
public actor PreviewWorkspaceProvider: WorkspaceProvider {
    private let latency: Duration
    // Not private: the layer snapshot reports the active clip's opacity so the
    // render surface can multiply it into the layer's. A stored-only opacity
    // fader that looks identical to a live one is the worst control in a VJ app.
    var opacities: [String: Double] = [:]
    // Blend is layer-owned, as it is in the engine. Keyed by layer id, valued
    // by the engine's `BlendMode` raw value.
    var layerBlendModes: [String: Int32] = [:]
    var playing = false
    var bpm: Double = 120
    var layerOpacities: [String: Double] = [:]
    var bypassedLayers: Set<String> = []
    var soloLayers: Set<String> = []
    var activeClips: [String: String] = [:]
    var masterOpacity: Double = 1
    var blackedOut = false
    let mediaClips: [MediaClip]
    let instances: [String: MediaClip]
    let populatedColumns: Int
    let columnCount: Int
    let deckTitle: String
    let effectDefinitions: [EffectDefinition]
    /// The blend modes the engine published. Injected for the same reason
    /// `effectDefinitions` is: the provider must reject a mode the renderer
    /// cannot run, and it cannot import the render package to find out which.
    /// Empty means nothing but the default has been published, so only the
    /// default is accepted — never "accept anything and hope".
    let blendModeOptions: [BlendModeOption]
    var effectStacks: [InspectorEffectScope: [InspectorEffect]] = [:]
    static let layerIDs = ["layer-4", "layer-3", "layer-2", "layer-1"]

    static let clips = [
        MediaClip(id: "violet-field", title: "Violet field", detail: "00:24 · HAP", artwork: .orbit),
        MediaClip(id: "contour", title: "Contour", detail: "00:18 · HAP", artwork: .contour),
        MediaClip(id: "noise-bloom", title: "Noise bloom", detail: "00:32 · DXV", artwork: .bloom),
        MediaClip(id: "monochrome", title: "Monochrome", detail: "00:16 · HAP", artwork: .monochrome),
        MediaClip(id: "afterlight", title: "Afterlight", detail: "00:28 · DXV", artwork: .bloom),
        MediaClip(id: "orbital", title: "Orbital", detail: "00:20 · HAP", artwork: .orbit),
        MediaClip(id: "line-study", title: "Line study", detail: "00:14 · HAP", artwork: .contour),
        MediaClip(id: "soft-focus", title: "Soft focus", detail: "00:22 · DXV", artwork: .monochrome),
    ]

    // Editable clip instances are distinct even when several slots use one asset.
    static func instanceID(layer: String, column: Int) -> String { "afterlight-\(layer)-clip-\(column)" }

    public init(latency: Duration = .milliseconds(320), clips: [MediaClip]? = nil, deckTitle: String = "Afterlight", effectDefinitions: [EffectDefinition] = [], blendModeOptions: [BlendModeOption] = []) {
        self.latency = latency
        self.blendModeOptions = blendModeOptions
        self.mediaClips = clips ?? Self.clips
        self.populatedColumns = clips?.count ?? 4
        self.columnCount = max(12, clips?.count ?? 4)
        self.deckTitle = deckTitle
        self.effectDefinitions = effectDefinitions
        let media = clips ?? Self.clips
        let count = clips?.count ?? 4
        self.instances = Dictionary(uniqueKeysWithValues:
            Self.layerIDs.enumerated().flatMap { row, layer in
                (0..<count).map { column in
                    let source = media[(row * 2 + column) % media.count]
                    let id = Self.instanceID(layer: layer, column: column)
                    return (id, MediaClip(id: id, title: source.title, detail: source.detail,
                        artwork: source.artwork, sourceID: source.id))
                }
            })
    }

    public func library() async throws -> LibrarySnapshot {
        try await pause()
        return LibrarySnapshot(clips: mediaClips)
    }

    public func preview(clipID: String?) async throws -> PreviewSnapshot {
        try await pause()
        return PreviewSnapshot(clip: try clip(clipID), width: 1920, height: 1080)
    }

    public func inspector(clipID: String?) async throws -> InspectorSnapshot {
        try await pause()
        let clip = try clip(clipID)
        return InspectorSnapshot(clip: clip, opacity: opacities[clip.id] ?? 1)
    }

    public func outputs() async throws -> OutputSnapshot {
        try await pause()
        return OutputSnapshot(outputs: [
            OutputDescriptor(id: "canvas-01", title: "Canvas 01", detail: "1920 × 1080 · Preview"),
            OutputDescriptor(id: "slice-01", title: "Slice 01", detail: "Quad warp · Preview"),
        ])
    }

    public func transport() async throws -> TransportSnapshot {
        try await pause()
        return TransportSnapshot(isPlaying: playing, bpm: bpm)
    }

    public func telemetry() async throws -> TelemetrySnapshot {
        try await pause()
        return TelemetrySnapshot(cpuMilliseconds: nil, gpuMilliseconds: nil, outputFPS: nil)
    }

    public func perform(_ action: WorkspaceAction) async throws {
        try Task.checkCancellation()
        switch action {
        case let .setOpacity(clipID, value):
            _ = try clip(clipID)
            guard value.isFinite, (0...1).contains(value) else {
                throw PanelIssue(title: "Change rejected", message: "Opacity must be between 0 and 100%.")
            }
            opacities[clipID] = value
        case let .setPlaying(value):
            playing = value
        case let .setBPM(value):
            // Matches `TransportSnapshot.validated()`. Rejecting here as well
            // means a bad tap never reaches the engine's `bpm`, which every
            // BPM-synced clip reads in the same frame.
            guard value.isFinite, (20...300).contains(value) else {
                throw PanelIssue(title: "Change rejected", message: "Tempo must be between 20 and 300 BPM.")
            }
            bpm = value
        case .addEffect, .removeEffect, .setEffectEnabled, .setEffectParameter, .moveEffect:
            try performEffect(action)
        default:
            try performLive(action)
        }
    }

    func pause() async throws {
        try await Task.sleep(for: latency)
        try Task.checkCancellation()
    }

    func clip(_ id: String?) throws -> MediaClip {
        let key = id ?? mediaClips.first?.id ?? ""
        guard let match = instances[key] ?? mediaClips.first(where: { $0.id == key }) else {
            throw PanelIssue(title: "Clip unavailable", message: "Choose another clip from the library.")
        }
        return match
    }
}
