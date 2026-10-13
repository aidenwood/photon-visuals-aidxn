import SwiftUI

struct ClipMatrixColumn: View {
    let model: WorkspaceModel
    let stack: LayerStackSnapshot
    let column: Int
    let rowHeight: CGFloat

    private var switchingDeck: Bool {
        model.layers.phase.isLoading && model.selectedDeckID != nil && model.selectedDeckID != stack.deckID
    }

    var body: some View {
        VStack(spacing: PhotonTheme.panelGap) {
            ColumnTrigger(column: column, trigger: { model.triggerColumn(column) })
                .frame(height: PhotonTheme.panelHeaderHeight).disabled(switchingDeck)
            ForEach(stack.layers) { layer in
                MatrixClipCell(
                    slot: layer.slot(in: column), activeID: layer.activeClipID,
                    selectedSlotID: model.selectedSlotID,
                    trigger: { model.triggerClip($0, layerID: layer.id, slotID: layer.slot(in: column)?.id) }
                )
                .frame(height: rowHeight).disabled(switchingDeck)
            }
        }
        .frame(width: 96)
    }
}
