import SwiftUI

struct PanelChrome<Content: View>: View {
    let title: String
    var detail: String? = nil
    var panelID: WorkspacePanelID? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(PhotonTheme.muted)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
                }
            }
            .padding(.horizontal, PhotonTheme.contentInset)
            .frame(height: PhotonTheme.panelHeaderHeight)
            Rectangle().fill(PhotonTheme.border).frame(height: 1)
            content()
        }
        .background(PhotonTheme.panel)
        .clipped()
        .overlay {
            Rectangle()
                .strokeBorder(PhotonTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier(panelID?.accessibilityIdentifier ?? "photon.panel.\(title)")
    }
}
