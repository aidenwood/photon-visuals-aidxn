import SwiftUI

struct DeckTabs: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        HStack(spacing: 2) {
            Text("DECKS").font(.system(size: 8, weight: .medium))
                .tracking(1).foregroundStyle(PhotonTheme.faint)
                .frame(width: 226, alignment: .leading).padding(.leading, 8)
            ForEach(model.layers.value?.decks ?? []) { deck in
                let selected = model.layers.value?.deckID == deck.id
                Button(deck.title) { model.selectDeck(deck.id) }
                    .font(.system(size: 10, weight: .medium)).buttonStyle(.plain)
                    .padding(.horizontal, 18).frame(height: 23)
                    .background(selected ? PhotonTheme.accent.opacity(0.18) : PhotonTheme.raised.opacity(0.5))
                    .foregroundStyle(selected ? PhotonTheme.accent : PhotonTheme.muted)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("photon.deck.\(deck.id)")
            }
            Spacer()
        }
        .padding(.top, 3)
    }
}
