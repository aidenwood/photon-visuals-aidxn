import SwiftUI

struct ClipMatrixPanel: View {
    let model: WorkspaceModel

    var body: some View {
        PanelChrome(title: "Composition", detail: "\(deckTitle.uppercased()) · UI PREVIEW", panelID: .clipMatrix) {
            PanelBoundary(model: model.layers, retry: { model.reloadLayers() }) { stack in
                GeometryReader { geometry in
                    let count = max(1, stack.layers.count)
                    let rowHeight = max(48, (geometry.size.height - 26 - 30 - 8 - CGFloat(count * 2)) / CGFloat(count))
                    VStack(spacing: 0) {
                        ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 2) {
                            LayerStrip(model: model, layers: stack.layers, rowHeight: rowHeight)
                                .frame(width: 230)
                            ScrollView(.horizontal) {
                                LazyHStack(spacing: 2) {
                                    ForEach(0..<stack.columns, id: \.self) { column in
                                        ClipMatrixColumn(model: model, stack: stack, column: column, rowHeight: rowHeight)
                                    }
                                }
                                .padding(.trailing, 4)
                            }
                        }
                        }
                        DeckTabs(model: model).frame(height: 30)
                    }
                    .padding(4)
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
