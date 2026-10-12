import SwiftUI

struct TelemetryReadout: View {
    let snapshot: TelemetrySnapshot

    var body: some View {
        HStack(spacing: 18) {
            metric("CPU", value: snapshot.cpuMilliseconds, suffix: "ms")
            metric("GPU", value: snapshot.gpuMilliseconds, suffix: "ms")
            metric("Output", value: snapshot.outputFPS, suffix: "fps")
        }
        .font(.system(size: 10)).monospacedDigit()
    }

    private func metric(_ name: String, value: Double?, suffix: String) -> some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(PhotonTheme.faint)
            Text(value.map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(suffix)" } ?? "—")
                .foregroundStyle(PhotonTheme.muted)
        }
        .accessibilityLabel("\(name): \(value.map { "\($0) \(suffix)" } ?? "unavailable")")
    }
}
