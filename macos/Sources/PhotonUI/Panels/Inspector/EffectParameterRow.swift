import SwiftUI

struct EffectParameterRow: View {
    let title: String
    let value: Double
    let change: (Double) -> Void

    var body: some View {
        ParameterRow(label: title) {
            HStack(spacing: 4) {
                ScrubbableNumber(value: value, label: title, change: change)
                Slider(value: Binding(get: { value }, set: { change($0) }), in: 0...1)
                    .controlSize(.mini).tint(PhotonTheme.accent).accessibilityLabel(title)
                Button { change(0.5) } label: {
                    Image(systemName: "arrow.counterclockwise").frame(width: 18, height: 22)
                }
                .buttonStyle(.plain).help("Reset \(title)").accessibilityLabel("Reset \(title)")
                Image(systemName: "waveform.path")
                    .foregroundStyle(PhotonTheme.faint).frame(width: 18, height: 22)
                    .help("No modulation assigned").accessibilityLabel("\(title): no modulation assigned")
            }
        }
    }
}
