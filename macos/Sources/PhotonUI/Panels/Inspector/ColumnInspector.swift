import SwiftUI

struct ColumnInspector: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { snapshot in
            if let column = model.selectedColumn {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(snapshot.layers) { layer in
                            InspectorSection(layer.title, detail: layer.slot(in: column)?.clip?.title ?? "Empty") {
                                if let clip = layer.slot(in: column)?.clip {
                                    InspectorSelectionView(clip: clip)
                                    Button("Inspect clip") { model.selectClip(clip.id) }
                                        .buttonStyle(.plain).foregroundStyle(PhotonTheme.accent)
                                } else {
                                    Text("Empty clip slot").font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
                                }
                            }
                        }
                        Button { model.triggerColumn(column) } label: {
                            Text("Trigger column")
                                .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
                                .background(PhotonTheme.raised, in: Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(PhotonTheme.accent)
                    }
                }
            } else {
                PanelEmptyView(symbol: "rectangle.split.3x1", title: "Select a column", detail: "Click a column trigger above the clips.")
            }
        } skeleton: { InspectorSkeleton() }
    }
}
