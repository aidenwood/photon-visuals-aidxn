import SwiftUI

struct LayerStrip: View {
    let model: WorkspaceModel
    let layers: [LayerSnapshot]
    let rowHeight: CGFloat

    var body: some View {
        VStack(spacing: PhotonTheme.panelGap) {
            HStack {
                Text("Layers").font(.system(size: 10, weight: .medium))
                Spacer()
                Text("Opacity / Blend").font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
            }
            .padding(.horizontal, PhotonTheme.contentInset).frame(height: PhotonTheme.panelHeaderHeight)
            .background(PhotonTheme.raised)
            ForEach(layers) { layer in
                LayerControlRow(
                    layer: layer,
                    selected: model.selectedLayerID == layer.id,
                    select: { model.selectLayer(layer.id) },
                    opacity: { model.setLayerOpacity($0, layerID: layer.id) },
                    bypass: { model.toggleLayerBypass(layer) },
                    solo: { model.toggleLayerSolo(layer) }
                )
                .frame(height: rowHeight)
                .effectDropTarget(model: model, scope: .layer(layer.id), label: layer.title)
            }
        }
    }
}
