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
            HStack(spacing: 8) {
                SkeletonBlock(width: PhotonTheme.controlHeight, height: PhotonTheme.controlHeight)
                SkeletonBlock(width: 80)
                Spacer()
                SkeletonBlock(width: 70)
            }
            .padding(.horizontal, PhotonTheme.contentInset)
        }
        .frame(height: 30)
        .background(PhotonTheme.panel)
        .overlay {
            Rectangle().strokeBorder(PhotonTheme.border)
        }
        .clipped()
        .accessibilityIdentifier(WorkspacePanelID.transport.accessibilityIdentifier)
    }
}
