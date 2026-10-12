import SwiftUI

struct LayerInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { snapshot in
            if let layer = snapshot.layers.first(where: { $0.id == model.selectedLayerID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(layer.title).font(.system(size: 12, weight: .medium))
                        Divider().overlay(PhotonTheme.border)
                        OpacityControl(value: layer.opacity) { model.setLayerOpacity($0, layerID: layer.id) }
                        Toggle("Bypass", isOn: Binding(get: { layer.bypass }, set: { _ in model.toggleLayerBypass(layer) }))
                        Toggle("Solo", isOn: Binding(get: { layer.solo }, set: { _ in model.toggleLayerSolo(layer) }))
                    }.font(.system(size: 11)).toggleStyle(.checkbox).padding(10).id(layer.id)
                }
            } else {
                PanelEmptyView(symbol: "square.3.layers.3d", title: "Select a layer", detail: "Click a layer name in the grid to edit its controls.")
            }
        } skeleton: { InspectorSkeleton() }
    }
}
