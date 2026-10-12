import SwiftUI

struct PanelChrome<Content: View>: View {
    let title: String
    var detail: String? = nil
    var panelID: WorkspacePanelID? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(PhotonTheme.muted)
                Spacer()
                if let detail {
                    Text(detail).font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 29)
            Rectangle().fill(PhotonTheme.border).frame(height: 1)
            content()
        }
        .background(PhotonTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: PhotonTheme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: PhotonTheme.radius)
                .strokeBorder(PhotonTheme.border, lineWidth: 1)
        }
        .accessibilityIdentifier(panelID?.accessibilityIdentifier ?? "photon.panel.\(title)")
    }
}
