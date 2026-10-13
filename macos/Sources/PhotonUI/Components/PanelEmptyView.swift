import SwiftUI

struct PanelEmptyView: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(PhotonTheme.faint)
            Text(title).font(.system(size: 11, weight: .medium))
            Text(detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(PhotonTheme.contentInset).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
