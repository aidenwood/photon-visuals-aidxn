import PhotonUI

@MainActor
struct SnapshotValidationTests {
    private let clip = MediaClip(id: "test", title: "Test", detail: "Preview", artwork: .orbit)

    func invalidPreviewDimensionsBecomePanelErrors() throws {
        try requirePanelIssue {
            _ = try PreviewSnapshot(clip: clip, width: 0, height: 1080).validated()
        }
    }

    func duplicateIDsBecomePanelErrors() throws {
        try requirePanelIssue { _ = try LibrarySnapshot(clips: [clip, clip]).validated() }
        let output = OutputDescriptor(id: "", title: "Output", detail: "Preview")
        try requirePanelIssue { _ = try OutputSnapshot(outputs: [output]).validated() }
    }

    func nonFiniteControlValuesBecomePanelErrors() throws {
        try requirePanelIssue {
            _ = try InspectorSnapshot(clip: clip, opacity: .nan).validated()
        }
        try requirePanelIssue {
            _ = try TransportSnapshot(isPlaying: false, bpm: .infinity).validated()
        }
    }

    func unknownTelemetryRemainsUnknown() throws {
        let snapshot = try TelemetrySnapshot(
            cpuMilliseconds: nil, gpuMilliseconds: nil, outputFPS: nil
        ).validated()
        try require(snapshot.outputFPS == nil)
        try require(snapshot.cpuMilliseconds == nil)
    }

    func malformedTelemetryBecomesAPanelError() throws {
        try requirePanelIssue {
            _ = try TelemetrySnapshot(
                cpuMilliseconds: -1, gpuMilliseconds: nil, outputFPS: nil
            ).validated()
        }
    }

    func previewProviderRejectsUnknownIDs() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        do {
            _ = try await provider.preview(clipID: "missing")
            throw CheckFailure(message: "Unknown clip ID was accepted.")
        } catch is PanelIssue {}
    }

    func malformedGridSlotsBecomePanelErrors() throws {
        func stack(_ slots: [ClipSlotSnapshot]) -> LayerStackSnapshot {
            LayerStackSnapshot(layers: [LayerSnapshot(id: "layer", title: "Layer", opacity: 1,
                bypass: false, solo: false, activeClipID: nil, slots: slots)], columns: 2)
        }
        let slot = ClipSlotSnapshot(id: "slot", column: 0, clip: clip)
        try requirePanelIssue { _ = try stack([slot, slot]).validated() }
        try requirePanelIssue { _ = try stack([slot, ClipSlotSnapshot(id: "other", column: 0, clip: clip)]).validated() }
        try requirePanelIssue { _ = try stack([ClipSlotSnapshot(id: "slot", column: 2, clip: nil)]).validated() }
        try requirePanelIssue { _ = try stack([ClipSlotSnapshot(id: "", column: 1, clip: nil)]).validated() }
    }
}
