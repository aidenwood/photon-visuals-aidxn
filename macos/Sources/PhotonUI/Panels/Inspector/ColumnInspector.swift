import SwiftUI

struct ColumnInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { snapshot in
            if let column = model.selectedColumn {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Column \(column + 1)").font(.system(size: 12, weight: .medium))
                        ForEach(snapshot.layers) { layer in
                            ParameterReadout(label: layer.title, value: layer.slot(in: column)?.clip?.title ?? "Empty")
                        }
                        Button("Trigger column") { model.triggerColumn(column) }
                            .buttonStyle(.bordered).controlSize(.small).tint(PhotonTheme.accent)
                    }.padding(14)
                }
            } else {
                PanelEmptyView(symbol: "rectangle.split.3x1", title: "Select a column", detail: "Click a column trigger above the clips.")
            }
        } skeleton: { InspectorSkeleton() }
    }
}
