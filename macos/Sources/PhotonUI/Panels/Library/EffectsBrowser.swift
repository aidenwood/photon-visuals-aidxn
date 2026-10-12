import SwiftUI

struct EffectsBrowser: View {
    let query: String

    private var matches: [EffectCatalogItem] {
        EffectCatalog.planned.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PLANNED LIBRARY").font(.system(size: 8, weight: .semibold)).tracking(1)
                .foregroundStyle(PhotonTheme.warning)
            if matches.isEmpty {
                PanelEmptyView(symbol: "magnifyingglass", title: "No matching effects", detail: "Try another name or category.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(matches) { effect in
                            HStack(spacing: 8) {
                                Image(systemName: "fx").font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(effect.name).font(.system(size: 11))
                                    Text(effect.category).font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
                            }
                            .padding(.horizontal, 6).padding(.vertical, 7)
                            .accessibilityLabel("\(effect.name), \(effect.category), planned; unavailable")
                        }
                    }
                }
            }
            Text("Effect processing is not connected yet.")
                .font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
        }
    }
}
