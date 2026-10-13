import SwiftUI

struct TransportControls: View {
    let snapshot: TransportSnapshot
    let busy: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            IconButton(
                symbol: snapshot.isPlaying ? "pause.fill" : "play.fill",
                label: snapshot.isPlaying ? "Pause preview controls" : "Play preview controls",
                action: toggle
            )
            .disabled(busy)
            Text("00:00:00").font(.system(size: 12, weight: .medium, design: .monospaced))
            Text("PREVIEW").font(.system(size: 8, weight: .semibold)).tracking(1.3)
                .foregroundStyle(PhotonTheme.faint)
            Spacer()
            Image(systemName: "metronome").foregroundStyle(PhotonTheme.accent)
            Text(snapshot.bpm.formatted(.number.precision(.fractionLength(0))))
                .monospacedDigit().font(.system(size: 12, weight: .medium))
            Text("BPM").font(.system(size: 9)).foregroundStyle(PhotonTheme.faint)
        }
        .padding(.horizontal, PhotonTheme.contentInset)
    }
}
