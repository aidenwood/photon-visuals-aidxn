import SwiftUI

struct LayerControlRow: View {
    let layer: LayerSnapshot
    let selected: Bool
    /// The layer's opacity including an in-progress drag, so the strip fader
    /// and the output never disagree about where the fader is.
    let liveOpacity: Double
    let blendModeOptions: [BlendModeOption]
    let select: () -> Void
    let opacity: (Double) -> Void
    let blend: (Int32) -> Void
    let bypass: () -> Void
    let solo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Button(layer.title, action: select)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? PhotonTheme.accent : PhotonTheme.foreground)
                Spacer()
                layerButton("B", active: layer.bypass, help: "Bypass \(layer.title)", action: bypass)
                layerButton("S", active: layer.solo, help: "Solo \(layer.title)", action: solo)
            }
            HStack(spacing: 4) {
                CompactBlendMenu(options: blendModeOptions, value: layer.blendModeID,
                                 title: layer.title, select: blend)
                LiveFader(value: liveOpacity, label: "\(layer.title) opacity", change: opacity)
            }
        }
        .padding(PhotonTheme.contentInset)
        .frame(maxHeight: .infinity, alignment: .center)
        .background(PhotonTheme.panel)
        .overlay { Rectangle().strokeBorder(selected ? PhotonTheme.accent.opacity(0.6) : PhotonTheme.border) }
        .opacity(layer.bypass ? 0.5 : 1)
    }

    private func layerButton(_ title: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 9, weight: .semibold))
            .buttonStyle(.plain)
            .frame(width: 23, height: 19)
            .background(active ? PhotonTheme.accent.opacity(0.25) : PhotonTheme.raised)
            .foregroundStyle(active ? PhotonTheme.accent : PhotonTheme.muted)
            .help(help).accessibilityLabel(help)
    }
}
