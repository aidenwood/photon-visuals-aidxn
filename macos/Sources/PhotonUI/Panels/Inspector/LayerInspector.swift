import SwiftUI

struct LayerInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { snapshot in
            if let layer = snapshot.layers.first(where: { $0.id == model.selectedLayerID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        InspectorSection(layer.title, detail: layer.bypass ? "Bypassed" : model.blendModeOptions.name(for: layer.blendModeID), expanded: true) {
                            OpacityControl(value: model.resolvedLayerOpacity(layer)) { model.setLayerOpacity($0, layerID: layer.id) }
                            // The layer's own blend — `LayerState.blend`. The
                            // Clip tab's Blend row edits this same value for
                            // whichever layer the clip is playing on; there is
                            // one blend per layer and this is it.
                            BlendModeControl(options: model.blendModeOptions, value: layer.blendModeID) {
                                model.setLayerBlendMode($0, layerID: layer.id)
                            }
                            HStack(spacing: 1) {
                                layerToggle("Bypass", active: layer.bypass) { model.toggleLayerBypass(layer) }
                                layerToggle("Solo", active: layer.solo) { model.toggleLayerSolo(layer) }
                            }
                        }
                        EffectStackView(model: model, scope: .layer(layer.id))
                            .effectDropTarget(model: model, scope: .layer(layer.id), label: layer.title)
                        InspectorSection("Modulation", detail: "Unbound") {
                            Text("No bindings for this layer.").font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                        }
                    }.id(layer.id)
                }
            } else {
                PanelEmptyView(symbol: "square.3.layers.3d", title: "Select a layer", detail: "Click a layer name in the grid to edit its controls.")
            }
        } skeleton: { InspectorSkeleton() }
    }

    private func layerToggle(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10))
                .padding(.horizontal, 8).frame(height: PhotonTheme.controlHeight)
                .background(active ? PhotonTheme.accent.opacity(0.25) : PhotonTheme.raised)
                .foregroundStyle(active ? PhotonTheme.accent : PhotonTheme.muted)
        }
        .buttonStyle(.plain).accessibilityValue(active ? "On" : "Off")
    }
}
