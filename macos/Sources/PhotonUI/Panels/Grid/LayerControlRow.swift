import SwiftUI

struct LayerControlRow: View {
    let layer: LayerSnapshot
    let selected: Bool
    let select: () -> Void
    let opacity: (Double) -> Void
    let bypass: () -> Void
    let solo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Button(layer.title, action: select)
                    .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(selected ? PhotonTheme.accent : PhotonTheme.foreground)
                Spacer()
                layerButton("B", active: layer.bypass, help: "Bypass \(layer.title)", action: bypass)
                layerButton("S", active: layer.solo, help: "Solo \(layer.title)", action: solo)
            }
            HStack(spacing: 8) {
                Text("Normal").font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
                LiveFader(value: layer.opacity, label: "\(layer.title) opacity", change: opacity)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
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
