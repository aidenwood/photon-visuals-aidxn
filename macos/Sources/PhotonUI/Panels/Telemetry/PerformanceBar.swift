import SwiftUI

struct PerformanceBar: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 16) {
            Text("AIDXN").font(.system(size: 9, weight: .semibold)).tracking(2)
                .foregroundStyle(PhotonTheme.faint)
            Rectangle().fill(PhotonTheme.border).frame(width: 1, height: 12)
            Text("Preview mode · Output inactive")
                .font(.system(size: 10)).foregroundStyle(PhotonTheme.muted).lineLimit(1)
            MasterControls(model: model)
            Spacer()
            TelemetryPanel(model: model.telemetry, retry: { model.reloadTelemetry() })
            .frame(width: 250, alignment: .trailing)
        }
        .padding(.horizontal, 14).frame(height: 40)
        .background(PhotonTheme.panel)
        .overlay(alignment: .top) { Rectangle().fill(PhotonTheme.border).frame(height: 1) }
        .accessibilityIdentifier(WorkspacePanelID.masterStrip.accessibilityIdentifier)
    }
}
