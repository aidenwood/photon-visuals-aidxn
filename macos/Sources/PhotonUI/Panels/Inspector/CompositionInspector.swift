import SwiftUI

struct CompositionInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.master, retry: { model.reloadMaster() }) { snapshot in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    InspectorSection("Composition", detail: "Master", expanded: true) {
                        OpacityControl(value: model.resolvedMasterOpacity, commit: model.setMasterOpacity)
                    }
                    InspectorSection("Output", detail: "1920 × 1080") {
                        ParameterReadout(label: "Canvas", value: "1920 × 1080")
                        ParameterReadout(label: "Blackout", value: snapshot.blackout ? "On" : "Off")
                    }
                    EffectStackView(model: model, scope: .composition)
                }
            }
        } skeleton: { InspectorSkeleton() }
    }
}
