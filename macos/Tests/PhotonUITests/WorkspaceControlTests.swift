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

    /// Busking: a fader held and moved must reach the renderer on every event,
    /// not once on release.
    ///
    /// Checked at the exact values `masterPlan` reads — `resolvedLayerOpacity`,
    /// `resolvedClipOpacity` and `resolvedMasterOpacity` are the plan's inputs,
    /// so a value visible here is a value the surface hands the engine on the
    /// next SwiftUI turn. **No awaits between the moves**: that is the point.
    /// The provider round-trip plus `ControlSnapshotRefresh`'s 80 ms debounce
    /// used to be the only path, and because that debounce cancels and
    /// restarts on every event, a continuous drag never let it fire — the
    /// output only moved ~80 ms after release.
    func draggingAFaderReachesTheRendererOnEveryEventNotOnRelease() async throws {
        let provider = ControlledProvider()
        let model = WorkspaceModel(provider: provider)
        await model.start()
        guard let layer = model.layers.value?.layers.first else {
            throw CheckFailure(message: "Missing layer fixture.")
        }
        guard let clip = layer.slot(in: 0)?.clip else {
            throw CheckFailure(message: "Missing populated fixture slot.")
        }

        // The provider is gated and deliberately never released, so nothing is
        // acknowledged for the whole of this check. Every value observed below
        // therefore came from the live override, not from a snapshot.
        for step in stride(from: 0.9, through: 0.1, by: -0.1) {
            model.setLayerOpacity(step, layerID: layer.id)
            try require(abs(model.resolvedLayerOpacity(layer) - step) < 1e-9)

            model.setMasterOpacity(step)
            try require(abs(model.resolvedMasterOpacity - step) < 1e-9)

            model.setOpacity(step, clipID: clip.id)
            try require(abs(model.resolvedClipOpacity(clipID: clip.id, acknowledged: 1) - step) < 1e-9)
        }
        // The acknowledged snapshot is still the pre-drag value, which is what
        // makes the point: the renderer was being fed by the override alone.
        try require(model.layers.value?.layers.first?.opacity == 1)
    }

    /// A rejected value must not be left sitting on the fader. The override is
    /// optimistic, so it has to retire when the provider refuses the change.
    func aRejectedFaderValueSnapsBackToWhatTheProviderHolds() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let model = WorkspaceModel(provider: provider)
        await model.start()
        guard let layer = model.layers.value?.layers.first else {
            throw CheckFailure(message: "Missing layer fixture.")
        }
        model.setLayerOpacity(0.4, layerID: "layer-does-not-exist")
        try await eventually { @MainActor in model.liveLayerOpacity["layer-does-not-exist"] == nil }
        try require(model.resolvedLayerOpacity(layer) == 1)
    }

    /// Clip opacity and layer opacity are two faders that multiply, and both
    /// values must survive the trip to the layer snapshot the renderer reads.
    /// Before this, clip opacity stopped at a provider dictionary.
    func clipOpacityAndLayerOpacityBothReachTheLayerSnapshot() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let initial = try await provider.layers()
        guard let layer = initial.layers.first, let clip = layer.slot(in: 0)?.clip else {
            throw CheckFailure(message: "Missing populated fixture slot.")
        }
        try await provider.perform(.triggerClip(clipID: clip.id, layerID: layer.id))
        try await provider.perform(.setOpacity(clipID: clip.id, value: 0.5))
        try await provider.perform(.setLayerOpacity(layerID: layer.id, value: 0.4))

        guard let after = try await provider.layers().layers.first(where: { $0.id == layer.id }) else {
            throw CheckFailure(message: "Layer vanished from the snapshot.")
        }
        try require(after.clipOpacity == 0.5)
        try require(after.opacity == 0.4)
        // The product is what the compositor applies to the layer.
        try require(abs(after.effectiveOpacity - 0.2) < 1e-9)
    }

    /// A clip that is not launched contributes no opacity term, rather than
    /// silently dimming a layer that is playing something else.
    func clipOpacityOnlyAppliesToTheLayerPlayingThatClip() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let initial = try await provider.layers()
        guard let layer = initial.layers.first, let clip = layer.slot(in: 1)?.clip else {
            throw CheckFailure(message: "Missing populated fixture slot.")
        }
        try await provider.perform(.setOpacity(clipID: clip.id, value: 0.25))
        guard let idle = try await provider.layers().layers.first(where: { $0.id == layer.id }) else {
            throw CheckFailure(message: "Layer vanished from the snapshot.")
        }
        try require(idle.clipOpacity == 1)
    }

    /// Every mode the renderer published must be settable and must come back
    /// as the id it was set to.
    ///
    /// Catalogue-driven on purpose. A check that counted modes, or listed their
    /// names, would be a second copy of `BlendMode` — and the last hand-written
    /// copy of that enum was missing `subtract`, which shifted every id above
    /// it and crashed on `darken`.
    func everyPublishedBlendModeRoundTripsToTheLayerSnapshot() async throws {
        let published = (0..<11).map { BlendModeOption(id: Int32($0), name: "Mode \($0)") }
        let provider = PreviewWorkspaceProvider(latency: .zero, blendModeOptions: published)
        guard let layer = try await provider.layers().layers.first else {
            throw CheckFailure(message: "Missing layer fixture.")
        }
        try require(layer.blendModeID == BlendModeOption.defaultID)
        for option in published {
            try await provider.perform(.setLayerBlendMode(layerID: layer.id, value: option.id))
            let after = try await provider.layers().layers.first { $0.id == layer.id }
            try require(after?.blendModeID == option.id)
        }
    }

    /// A mode outside the published catalogue is refused where the operator
    /// can see it, instead of being dropped at the render seam and composited
    /// as Over while the menu still shows the name that was picked.
    func aBlendModeTheRendererNeverPublishedIsRefused() async throws {
        let published = [BlendModeOption(id: 0, name: "Over"), BlendModeOption(id: 1, name: "Add")]
        let provider = PreviewWorkspaceProvider(latency: .zero, blendModeOptions: published)
        guard let layer = try await provider.layers().layers.first else {
            throw CheckFailure(message: "Missing layer fixture.")
        }
        do {
            try await provider.perform(.setLayerBlendMode(layerID: layer.id, value: 99))
            throw CheckFailure(message: "Expected an unpublished blend mode to be refused.")
        } catch is PanelIssue {}
        let after = try await provider.layers().layers.first { $0.id == layer.id }
        try require(after?.blendModeID == BlendModeOption.defaultID)
    }

    /// Play/pause and tempo have to land in the transport snapshot, because
    /// that snapshot is what the render surface turns into `engine.isPlaying`
    /// and `engine.bpm`. Both were fixtures: `setPlaying` went nowhere and the
    /// BPM was the literal 120.
    func transportAndTempoReachTheSnapshotTheRendererReads() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        var transport = try await provider.transport()
        try require(transport.isPlaying == false)
        try await provider.perform(.setPlaying(true))
        transport = try await provider.transport()
        try require(transport.isPlaying == true)
        try await provider.perform(.setBPM(142))
        transport = try await provider.transport()
        try require(transport.bpm == 142)
        // Out of range is refused rather than clamped, so a bad tap cannot
        // quietly retune every BPM-synced clip in the composition.
        do {
            try await provider.perform(.setBPM(4000))
            throw CheckFailure(message: "Expected an out-of-range tempo to be refused.")
        } catch is PanelIssue {}
        transport = try await provider.transport()
        try require(transport.bpm == 142)
    }

    /// Tap tempo converts tap spacing into BPM and commits it.
    func tapTempoCommitsTheTappedTempo() async throws {
        let provider = PreviewWorkspaceProvider(latency: .zero)
        let model = WorkspaceModel(provider: provider)
        await model.start()
        // Four taps 0.5 s apart is 120 BPM.
        let start = Date()
        for index in 0..<4 { model.tapTempo(at: start.addingTimeInterval(0.5 * Double(index))) }
        try await eventually { @MainActor in model.transport.value?.bpm == 120 }

        // A gap longer than the timeout restarts the count rather than
        // averaging a tempo nobody played across the pause.
        model.tapTempo(at: start.addingTimeInterval(60))
        try await eventually { @MainActor in model.transport.value?.bpm == 120 }
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
