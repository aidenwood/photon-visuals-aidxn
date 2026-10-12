import SwiftUI

struct PanelFailureView: View {
    let issue: PanelIssue
    var compact = false
    let retry: () -> Void

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(PhotonTheme.warning)
                .font(.system(size: compact ? 12 : 22))
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.system(size: compact ? 10 : 12, weight: .medium)).lineLimit(compact ? 1 : nil)
                if !compact { Text(issue.message)
                    .font(.system(size: 11))
                    .foregroundStyle(PhotonTheme.muted)
                    .fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 6)
            Button("Retry", action: retry)
                .buttonStyle(.plain)
                .font(.system(size: compact ? 10 : 11, weight: .medium))
                .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 5 : 7)
                .background(PhotonTheme.accent.opacity(0.2), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("Retry \(issue.title)")
        }
        .padding(compact ? 8 : 20)
        .background(PhotonTheme.raised, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(PhotonTheme.warning.opacity(0.25))
        }
        .padding(compact ? 0 : 16)
        .help(issue.message)
    }
}
