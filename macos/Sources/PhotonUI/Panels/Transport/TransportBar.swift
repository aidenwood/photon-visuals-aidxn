import SwiftUI

struct TransportBar: View {
    let model: WorkspaceModel

    var body: some View {
        PanelBoundary(model: model.transport, retry: { model.reloadTransport() }) { snapshot in
            TransportControls(
                snapshot: snapshot, busy: model.transport.phase.isLoading,
                toggle: model.togglePlayback
            )
        } skeleton: {
            HStack(spacing: 16) {
                SkeletonBlock(width: 28, height: 28)
                SkeletonBlock(width: 80)
                Spacer()
                SkeletonBlock(width: 70)
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 52)
        .background(PhotonTheme.panel, in: RoundedRectangle(cornerRadius: PhotonTheme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: PhotonTheme.radius).strokeBorder(PhotonTheme.border)
        }
        .clipShape(RoundedRectangle(cornerRadius: PhotonTheme.radius))
        .accessibilityIdentifier(WorkspacePanelID.transport.accessibilityIdentifier)
    }
}
