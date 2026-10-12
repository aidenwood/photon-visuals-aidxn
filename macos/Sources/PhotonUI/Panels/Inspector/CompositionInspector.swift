import SwiftUI

struct CompositionInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.master, retry: { model.reloadMaster() }) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Afterlight").font(.system(size: 12, weight: .medium))
                    Text("Preview composition").font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                    Divider().overlay(PhotonTheme.border)
                    OpacityControl(value: snapshot.opacity, commit: model.setMasterOpacity)
                    ParameterReadout(label: "Canvas", value: "1920 × 1080")
                    ParameterReadout(label: "Blackout", value: snapshot.blackout ? "On" : "Off")
                }.padding(10)
            }
        } skeleton: { InspectorSkeleton() }
    }
}
