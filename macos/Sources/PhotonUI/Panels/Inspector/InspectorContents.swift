import SwiftUI

struct InspectorContents: View {
    let model: WorkspaceModel
    let snapshot: InspectorSnapshot
    let setOpacity: (Double) -> Void

    /// The layer this clip is currently playing on, if any.
    ///
    /// Blend belongs to the layer, so the Clip tab's Blend row needs to know
    /// which layer it would be editing. A clip sitting unlaunched in the grid
    /// is not on one, and the control says so rather than accepting a pick
    /// that has nowhere to land.
    private var hostLayer: LayerSnapshot? {
        model.layers.value?.layers.first { $0.activeClipID == snapshot.clip.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            InspectorSelectionView(clip: snapshot.clip)
                .padding(PhotonTheme.contentInset)
            InspectorSection("Video", detail: videoDetail, expanded: true) {
                OpacityControl(value: model.resolvedClipOpacity(clipID: snapshot.clip.id, acknowledged: snapshot.opacity), commit: setOpacity)
                BlendModeControl(
                    options: model.blendModeOptions,
                    value: hostLayer?.blendModeID ?? BlendModeOption.defaultID,
                    select: { mode in
                        guard let host = hostLayer else { return }
                        model.setLayerBlendMode(mode, layerID: host.id)
                    },
                    unavailable: hostLayer == nil ? "Launch to set" : nil
                )
            }
            InspectorSection("Transform", detail: "Position · Scale · Rotation") {
                ParameterReadout(label: "Position", value: "0, 0")
                ParameterReadout(label: "Scale", value: "100%")
                ParameterReadout(label: "Rotation", value: "0°")
            }
            EffectStackView(model: model, scope: .clip(snapshot.clip.id))
                .effectDropTarget(model: model, scope: .clip(snapshot.clip.id), label: snapshot.clip.title)
            InspectorSection("Modulation", detail: "Unbound") {
                Text("No bindings for this clip.")
                    .font(.system(size: 11)).foregroundStyle(PhotonTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }

    /// Names the layer the blend row is reaching, so the section header never
    /// implies a mode is set on a clip that is not playing anywhere.
    private var videoDetail: String {
        guard let host = hostLayer else { return "Not launched" }
        return "\(host.title) · \(model.blendModeOptions.name(for: host.blendModeID))"
    }
}
