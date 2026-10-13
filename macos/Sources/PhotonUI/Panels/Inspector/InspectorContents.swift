import SwiftUI

struct InspectorContents: View {
    let model: WorkspaceModel
    let snapshot: InspectorSnapshot
    let setOpacity: (Double) -> Void
    let setBlend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            InspectorSelectionView(clip: snapshot.clip)
                .padding(PhotonTheme.contentInset)
            InspectorSection("Video", detail: snapshot.blendMode, expanded: true) {
                OpacityControl(value: snapshot.opacity, commit: setOpacity)
                BlendModeControl(value: snapshot.blendMode, select: setBlend)
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
}
