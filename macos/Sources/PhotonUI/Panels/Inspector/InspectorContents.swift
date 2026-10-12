import SwiftUI

struct InspectorContents: View {
    let snapshot: InspectorSnapshot
    let setOpacity: (Double) -> Void
    let setBlend: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            InspectorSelectionView(clip: snapshot.clip)
            Divider().overlay(PhotonTheme.border)
            OpacityControl(value: snapshot.opacity, commit: setOpacity)
            BlendModeControl(value: snapshot.blendMode, select: setBlend)
            Divider().overlay(PhotonTheme.border)
            VStack(alignment: .leading, spacing: 3) {
                Text("TRANSFORM").font(.system(size: 9, weight: .semibold))
                    .tracking(1.4).foregroundStyle(PhotonTheme.faint)
                ParameterReadout(label: "Position", value: "0, 0")
                ParameterReadout(label: "Scale", value: "100%")
                ParameterReadout(label: "Rotation", value: "0°")
            }
            Divider().overlay(PhotonTheme.border)
            VStack(alignment: .leading, spacing: 8) {
                Text("BINDINGS").font(.system(size: 9, weight: .semibold))
                    .tracking(1.4).foregroundStyle(PhotonTheme.faint)
                Text("No bindings for this clip.")
                    .font(.system(size: 11)).foregroundStyle(PhotonTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
    }
}
