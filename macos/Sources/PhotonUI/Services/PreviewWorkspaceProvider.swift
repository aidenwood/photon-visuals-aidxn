import Foundation

/// UI fixtures only: no media decoder, renderer, hardware output, or measured FPS.
public actor PreviewWorkspaceProvider: WorkspaceProvider {
    private let latency: Duration
    private var opacities: [String: Double] = [:]
    private var blendModes: [String: String] = [:]
    var playing = false
    var layerOpacities: [String: Double] = [:]
    var bypassedLayers: Set<String> = []
    var soloLayers: Set<String> = []
    var activeClips: [String: String] = [:]
    var masterOpacity: Double = 1
    var blackedOut = false
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
    static let instances: [String: MediaClip] = Dictionary(uniqueKeysWithValues:
        layerIDs.enumerated().flatMap { row, layer in
            (0..<4).map { column in
                let source = clips[(row * 2 + column) % clips.count]
                let id = instanceID(layer: layer, column: column)
                return (id, MediaClip(id: id, title: source.title, detail: source.detail,
                    artwork: source.artwork, sourceID: source.id))
            }
        })

    static func instanceID(layer: String, column: Int) -> String { "afterlight-\(layer)-clip-\(column)" }

    public init(latency: Duration = .milliseconds(320)) { self.latency = latency }

    public func library() async throws -> LibrarySnapshot {
        try await pause()
        return LibrarySnapshot(clips: Self.clips)
    }

    public func preview(clipID: String?) async throws -> PreviewSnapshot {
        try await pause()
        return PreviewSnapshot(clip: try clip(clipID), width: 1920, height: 1080)
    }

    public func inspector(clipID: String?) async throws -> InspectorSnapshot {
        try await pause()
        let clip = try clip(clipID)
        return InspectorSnapshot(
            clip: clip, opacity: opacities[clip.id] ?? 1,
            blendMode: blendModes[clip.id] ?? "Normal"
        )
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
        return TransportSnapshot(isPlaying: playing, bpm: 120)
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
        case let .setBlendMode(clipID, value):
            _ = try clip(clipID)
            guard ["Normal", "Add", "Multiply", "Screen"].contains(value) else {
                throw PanelIssue(title: "Change rejected", message: "This blend mode is unavailable.")
            }
            blendModes[clipID] = value
        case let .setPlaying(value):
            playing = value
        default:
            try performLive(action)
        }
    }

    func pause() async throws {
        try await Task.sleep(for: latency)
        try Task.checkCancellation()
    }

    func clip(_ id: String?) throws -> MediaClip {
        let key = id ?? "violet-field"
        guard let match = Self.instances[key] ?? Self.clips.first(where: { $0.id == key }) else {
            throw PanelIssue(title: "Clip unavailable", message: "Choose another clip from the library.")
        }
        return match
    }
}
