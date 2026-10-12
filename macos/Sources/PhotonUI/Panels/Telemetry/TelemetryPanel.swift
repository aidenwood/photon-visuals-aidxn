import SwiftUI

struct TelemetryPanel: View {
    let model: PanelModel<TelemetrySnapshot>
    let retry: () -> Void

    var body: some View {
        Group {
            if let issue = model.phase.issue {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(PhotonTheme.warning)
                    Text("Metrics unavailable").foregroundStyle(PhotonTheme.muted)
                    Button("Retry", action: retry).buttonStyle(.plain).foregroundStyle(PhotonTheme.accent)
                }
                .font(.system(size: 10)).help(issue.message)
            } else if let snapshot = model.value {
                TelemetryReadout(snapshot: snapshot)
            } else {
                HStack(spacing: 18) {
                    SkeletonBlock(width: 65, height: 8)
                    SkeletonBlock(width: 65, height: 8)
                    SkeletonBlock(width: 65, height: 8)
                }
                .accessibilityLabel("Metrics loading")
            }
        }
    }
}
