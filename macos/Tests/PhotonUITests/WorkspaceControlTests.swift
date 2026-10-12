import Foundation
import PhotonUI

@MainActor
struct WorkspaceControlTests {
    func continuousControlsCoalesceWithoutCrossingTriggers() async throws {
        let provider = ControlledProvider()
        let model = WorkspaceModel(provider: provider)
        model.setOpacity(0.2, clipID: "violet-field")
        try await eventually { await provider.hasStarted }
        model.setOpacity(0.4, clipID: "violet-field")
        model.setOpacity(0.9, clipID: "violet-field")
        model.triggerColumn(0)
        model.setOpacity(0.7, clipID: "violet-field")
        await provider.release()
        try await eventually { await provider.completed.count == 4 }
        let completed = await provider.completed
        try require(completed == ["opacity:0.2", "opacity:0.9", "column:0", "opacity:0.7"])
    }

    func cancellingMetadataDoesNotCancelAnAcceptedControl() async throws {
        let provider = ControlledProvider()
        let model = WorkspaceModel(provider: provider)
        model.selectClip("violet-field")
        model.setOpacity(0.25, clipID: "violet-field")
        try await eventually { await provider.hasStarted }
        model.inspector.cancel()
        await provider.release()
        try await eventually { await provider.completed.count == 1 }
        await model.reloadInspector().value
        try require(model.inspector.value?.opacity == 0.25)
    }

    func rapidBlackoutPressesUseTheLatestRequestedState() async throws {
        let provider = ControlledProvider()
        let model = WorkspaceModel(provider: provider)
        model.toggleBlackout()
        try require(model.isBlackedOut)
        try await eventually { await provider.hasStarted }
        model.toggleBlackout()
        try require(!model.isBlackedOut)
        await provider.release()
        try await eventually { await provider.completed.count == 2 }
        let completed = await provider.completed
        try require(completed == ["blackout:true", "blackout:false"])
        await model.reloadMaster().value
        try require(model.master.value?.blackout == false)
    }

    func browsingAnEmptyDeckKeepsPlayingClips() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let initial = try await provider.layers()
        guard let layer = initial.layers.first, let clip = layer.slot(in: 0)?.clip else {
            throw CheckFailure(message: "Missing populated fixture slot.")
        }
        try await provider.perform(.triggerClip(clipID: clip.id, layerID: layer.id))
        let empty = try await provider.layers(deckID: "empty")
        try require(empty.layers.allSatisfy { $0.slots.allSatisfy { $0.clip == nil } })
        try require(empty.layers.first?.activeClipID == clip.id)
        try await provider.perform(.triggerColumn(column: 0, deckID: "empty"))
        let after = try await provider.layers()
        try require(after.layers.first?.activeClipID == clip.id)
    }

    func clipInstancesHaveIndependentControlsForASharedAsset() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let snapshot = try await provider.layers()
        let clips = snapshot.layers.flatMap { $0.slots.compactMap(\.clip) }
        guard let first = clips.first,
              let second = clips.first(where: { $0.id != first.id && $0.assetID == first.assetID }) else {
            throw CheckFailure(message: "Missing shared-asset clip instances.")
        }
        try await provider.perform(.setOpacity(clipID: first.id, value: 0.3))
        let a = try await provider.inspector(clipID: first.id)
        let b = try await provider.inspector(clipID: second.id)
        try require(a.opacity == 0.3)
        try require(b.opacity == 1)
        try require(a.clip.assetID == b.clip.assetID)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure(message: "Control did not finish within the functional-check deadline.")
    }
}

/// Gates only the first command. No render, decoder or timing benchmark involved.
private actor ControlledProvider: WorkspaceProvider {
    let fixture = PreviewWorkspaceProvider(latency: .zero)
    var completed: [String] = []
    var hasStarted = false
    private var continuation: CheckedContinuation<Void, Never>?

    func release() { continuation?.resume(); continuation = nil }

    func perform(_ action: WorkspaceAction) async throws {
        if !hasStarted {
            hasStarted = true
            await withCheckedContinuation { continuation = $0 }
        }
        try await fixture.perform(action)
        switch action {
        case let .setOpacity(_, value): completed.append("opacity:\(value)")
        case let .triggerColumn(column, _): completed.append("column:\(column)")
        case let .setBlackout(value): completed.append("blackout:\(value)")
        default: completed.append("other")
        }
    }

    func library() async throws -> LibrarySnapshot { try await fixture.library() }
    func preview(clipID: String?) async throws -> PreviewSnapshot { try await fixture.preview(clipID: clipID) }
    func masterPreview() async throws -> PreviewSnapshot { try await fixture.masterPreview() }
    func inspector(clipID: String?) async throws -> InspectorSnapshot { try await fixture.inspector(clipID: clipID) }
    func outputs() async throws -> OutputSnapshot { try await fixture.outputs() }
    func transport() async throws -> TransportSnapshot { try await fixture.transport() }
    func telemetry() async throws -> TelemetrySnapshot { try await fixture.telemetry() }
    func layers(deckID: String?) async throws -> LayerStackSnapshot { try await fixture.layers(deckID: deckID) }
    func master() async throws -> MasterSnapshot { try await fixture.master() }
}
