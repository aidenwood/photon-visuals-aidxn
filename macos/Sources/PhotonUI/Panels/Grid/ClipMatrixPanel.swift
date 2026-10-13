import SwiftUI

struct ClipMatrixPanel: View {
    let model: WorkspaceModel

    var body: some View {
        PanelChrome(title: "Composition", detail: "\(deckTitle.uppercased()) · UI PREVIEW", panelID: .clipMatrix) {
            PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { stack in
                GeometryReader { geometry in
                    let count = max(1, stack.layers.count)
                    let rowHeight = max(44, (geometry.size.height - PhotonTheme.panelHeaderHeight
                        - PhotonTheme.deckBarHeight - CGFloat(count) * PhotonTheme.panelGap) / CGFloat(count))
                    VStack(spacing: 0) {
                        ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: PhotonTheme.panelGap) {
                            LayerStrip(model: model, layers: stack.layers, rowHeight: rowHeight)
                                .frame(width: PhotonTheme.layerStripWidth)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: PhotonTheme.panelGap) {
                                    ForEach(0..<stack.columns, id: \.self) { column in
                                        ClipMatrixColumn(model: model, stack: stack, column: column, rowHeight: rowHeight)
                                    }
                                }
                            }
                        }
                        }
                        DeckTabs(model: model).frame(height: PhotonTheme.deckBarHeight)
                    }
                }
            } skeleton: {
                MatrixSkeleton()
            }
        }
    }

    private var deckTitle: String {
        guard let stack = model.layers.value else { return "Composition" }
        return stack.decks.first(where: { $0.id == stack.deckID })?.title ?? "Composition"
    }
}
