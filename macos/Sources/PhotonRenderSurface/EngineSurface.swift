// Bridges the engine's Metal view into PhotonUI's `ProgramSurfaceFactory`.
//
// This is the only file that knows about both sides. PhotonUI stays free of
// Metal and FFI; the engine stays free of SwiftUI layout concerns.

import SwiftUI
import PhotonUI

/// What one monitor must show, resolved from the workspace's acknowledged state.
///
/// A value type on purpose: SwiftUI diffs it and the Metal view ignores an
/// unchanged plan, so a redraw of unrelated chrome never restarts a clip.
struct SurfacePlan: Equatable {
    /// One link of a layer's chain, carried as the engine's `EffectKind` raw
    /// value so PhotonUI never has to import the render package.
    struct Effect: Equatable {
        var kind: Int32
        var amount: Double
        var param: Double
        var enabled: Bool
    }

    struct Layer: Equatable {
        var name: String
        var url: URL?
        /// The layer's master fader.
        var opacity: Double
        /// The launched clip's own fader. Kept separate from `opacity` and
        /// multiplied into it at the engine, because they are two controls in
        /// the inspector and the operator must be able to move either one
        /// without the other's value being lost.
        var clipOpacity: Double = 1
        /// The engine's `BlendMode` raw value. An id rather than a name: a
        /// name needs a translation table, and the table drifted from the enum
        /// once already.
        var blendModeID: Int32
        var bypassed: Bool
        var soloed: Bool
        var effects: [Effect] = []
    }

    var layers: [Layer] = []
    var masterOpacity: Double = 1
    var blackout: Bool = false
    /// Transport. `false` pauses every source; the composite keeps presenting
    /// the held frame rather than going black, because a pause is not a cut.
    var playing: Bool = true
    var bpm: Double = 120
}

/// Only a real file on disk can be played. A fixture's asset ID is a bare name,
/// not a URL; it must resolve to nothing rather than to stand-in media, because
/// unrelated footage shown as the operator's clip is worse than a black panel.
private func mediaURL(_ assetID: String) -> URL? {
    guard let url = URL(string: assetID), url.isFileURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return url
}

/// The composite: every layer's launched clip, in draw order.
@MainActor private func masterPlan(_ model: WorkspaceModel) -> SurfacePlan {
    guard let stack = model.layers.value else { return SurfacePlan() }
    // The layer strip lists the top layer first; the compositor draws bottom-up.
    let layers = stack.layers.reversed().map { layer -> SurfacePlan.Layer in
        let url = layer.activeClipID
            .flatMap { active in layer.slots.compactMap(\.clip).first { $0.id == active } }
            .flatMap { mediaURL($0.assetID) }
        return SurfacePlan.Layer(
            name: layer.title,
            url: url,
            // Resolved, not raw. A fader being dragged publishes its value on
            // the model immediately; the acknowledged snapshot catches up
            // ~80 ms later. Reading the snapshot alone is what made every
            // fader commit only on release.
            opacity: model.resolvedLayerOpacity(layer),
            clipOpacity: model.resolvedClipOpacity(layer),
            blendModeID: layer.blendModeID,
            // A layer with nothing launched is excluded outright: an empty
            // layer left in the stack falls through to the engine's procedural
            // kind, which would read as content the operator never triggered.
            bypassed: layer.bypass || url == nil,
            soloed: layer.solo,
            effects: surfaceEffects(model.renderChain(layerID: layer.id, activeClipID: layer.activeClipID))
        )
    }
    // Transport belongs to the composite. Until the first snapshot lands the
    // engine keeps running: a monitor that starts frozen because metadata is
    // still in flight looks exactly like a decode failure.
    let transport = model.transport.value
    return SurfacePlan(
        layers: layers,
        masterOpacity: model.resolvedMasterOpacity,
        blackout: model.isBlackedOut,
        playing: transport?.isPlaying ?? true,
        bpm: transport?.bpm ?? 120
    )
}

/// The inspector's chain, in the shape the Metal view consumes.
@MainActor private func surfaceEffects(_ chain: [InspectorEffect]) -> [SurfacePlan.Effect] {
    chain.map {
        SurfacePlan.Effect(kind: $0.definitionID, amount: $0.amount,
                           param: $0.parameter, enabled: $0.enabled)
    }
}

/// A clip monitor is pre-composite by definition — one source, no master trim.
@MainActor private func clipPlan(_ model: WorkspaceModel, _ snapshot: PreviewSnapshot) -> SurfacePlan {
    let url = mediaURL(snapshot.clip.assetID)
    // Pre-composite: there is nothing underneath, so blending is meaningless.
    // The clip's own chain still runs — it belongs to the source, not the
    // composite, so the monitor must show what the operator just added.
    // Pre-composite also means pre-transport: this monitor exists to show what
    // a source *is* before it is committed, so it keeps running while the
    // composition is paused — the same rule that keeps it off master and
    // blackout. Tempo still follows the project so a BPM-synced clip previews
    // at the speed it will play at.
    return SurfacePlan(layers: [SurfacePlan.Layer(
        name: snapshot.clip.title, url: url, opacity: 1,
        blendModeID: BlendModeOption.defaultID,
        bypassed: url == nil, soloed: false,
        effects: surfaceEffects(model.renderEffects[.clip(snapshot.clip.id)] ?? [])
    )], playing: true, bpm: model.transport.value?.bpm ?? 120)
}

/// SwiftUI wrapper around the engine's Metal view.
private struct ProgramSurfaceRepresentable: NSViewRepresentable {
    let role: SurfaceRole
    let plan: SurfacePlan
    var mapping: MappingQuad? = nil

    func makeNSView(context: Context) -> NSView {
        // If Metal is unavailable the panel must degrade, not crash — a
        // failed preview can never be allowed to take the app down mid-show.
        guard let view = ProgramMetalView.make(role: role) else {
            let fallback = NSView()
            fallback.wantsLayer = true
            fallback.layer?.backgroundColor = NSColor.black.cgColor
            return fallback
        }
        view.apply(plan)
        if let mapping { view.setMappingCorners(mapping.corners) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ProgramMetalView)?.apply(plan)
        if let mapping { (nsView as? ProgramMetalView)?.setMappingCorners(mapping.corners) }
    }
}

public extension ProgramSurfaceFactory {
    /// The live engine surface. Pass to `PhotonWorkspace(model:programSurface:)`.
    ///
    /// Without this the preview panels fall back to static artwork — which is
    /// why an un-injected preview monitor looks like it "doesn't work".
    ///
    /// The model is read inside the factory closure, which SwiftUI evaluates
    /// inside a view body: observation therefore re-runs it when a grid trigger
    /// changes the layer stack, and the new plan reaches the engine.
    static func engine(model: WorkspaceModel) -> ProgramSurfaceFactory {
        ProgramSurfaceFactory(content: .workspace, mappingView: { _, quad in
            AnyView(ProgramSurfaceRepresentable(role: .master, plan: masterPlan(model), mapping: quad))
        }) { snapshot, role in
            AnyView(
                ProgramSurfaceRepresentable(
                    role: role == .master ? .master : .clip,
                    plan: role == .master ? masterPlan(model) : clipPlan(model, snapshot)
                )
            )
        }
    }
}
