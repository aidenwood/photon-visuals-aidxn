import Foundation

// Presentation DTOs only. These are not the .photon document or wire schema.
public enum ArtworkStyle: String, CaseIterable, Sendable {
    case orbit, contour, bloom, monochrome, empty
}

public struct MediaClip: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let artwork: ArtworkStyle
    /// Shared media identity; `id` is the editable clip instance in grid/inspector snapshots.
    /// Library assets may omit this and use their own ID.
    public let sourceID: String?
    public var assetID: String { sourceID ?? id }

    public init(id: String, title: String, detail: String, artwork: ArtworkStyle, sourceID: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.artwork = artwork
        self.sourceID = sourceID
    }
}

public struct LibrarySnapshot: Sendable {
    public let clips: [MediaClip]
    public init(clips: [MediaClip]) { self.clips = clips }

    public func validated() throws -> Self {
        let ids = clips.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw PanelIssue(title: "Library unavailable", message: "The clip identifiers are invalid.")
        }
        return self
    }
}

public struct PreviewSnapshot: Sendable {
    public let clip: MediaClip
    public let width: Int
    public let height: Int

    public init(clip: MediaClip, width: Int, height: Int) {
        self.clip = clip
        self.width = width
        self.height = height
    }

    public func validated() throws -> Self {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else {
            throw PanelIssue(title: "Preview unavailable", message: "The preview dimensions are invalid.")
        }
        return self
    }
}

/// The Clip tab's own state.
///
/// Carries no blend mode. Blending is a property of a **layer** in the engine
/// (`LayerState.blend`) and in Resolume, and there is exactly one of them per
/// layer; a per-clip copy had nowhere to go and was stored and discarded. The
/// Clip tab still offers a Blend control — it edits the blend of the layer the
/// clip is playing on, read live from the layer stack.
public struct InspectorSnapshot: Sendable {
    public let clip: MediaClip
    public let opacity: Double

    public init(clip: MediaClip, opacity: Double) {
        self.clip = clip
        self.opacity = opacity
    }

    public func validated() throws -> Self {
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw PanelIssue(title: "Inspector unavailable", message: "The opacity value is invalid.")
        }
        return self
    }
}

public struct OutputDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let detail: String

    public init(id: String, title: String, detail: String) {
        self.id = id
        self.title = title
        self.detail = detail
    }
}

public struct OutputSnapshot: Sendable {
    public let outputs: [OutputDescriptor]
    public init(outputs: [OutputDescriptor]) { self.outputs = outputs }

    public func validated() throws -> Self {
        let ids = outputs.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else {
            throw PanelIssue(title: "Outputs unavailable", message: "The output identifiers are invalid.")
        }
        return self
    }
}

public struct TransportSnapshot: Sendable {
    public let isPlaying: Bool
    public let bpm: Double

    public init(isPlaying: Bool, bpm: Double) {
        self.isPlaying = isPlaying
        self.bpm = bpm
    }

    public func validated() throws -> Self {
        guard bpm.isFinite, (20...300).contains(bpm) else {
            throw PanelIssue(title: "Transport unavailable", message: "The tempo value is invalid.")
        }
        return self
    }
}

public struct TelemetrySnapshot: Sendable {
    public let cpuMilliseconds: Double?
    public let gpuMilliseconds: Double?
    public let outputFPS: Double?

    public init(cpuMilliseconds: Double?, gpuMilliseconds: Double?, outputFPS: Double?) {
        self.cpuMilliseconds = cpuMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.outputFPS = outputFPS
    }

    public func validated() throws -> Self {
        let values = [cpuMilliseconds, gpuMilliseconds, outputFPS].compactMap { $0 }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw PanelIssue(title: "Metrics unavailable", message: "The metric values are invalid.")
        }
        return self
    }
}
