import SwiftUI

struct MatrixClipCell: View {
    let slot: ClipSlotSnapshot?
    let activeID: String?
    let selectedSlotID: String?
    let trigger: (String) -> Void

    var body: some View {
        Group {
            if let clip = slot?.clip {
                Button { trigger(clip.id) } label: {
                    VStack(spacing: 0) {
                        ClipArtworkView(clip: clip)
                            .overlay(alignment: .topLeading) {
                                if activeID == clip.id {
                                    Image(systemName: "play.fill").font(.system(size: 8))
                                        .padding(3).background(PhotonTheme.accent).padding(2)
                                }
                            }
                        HStack {
                            Text(clip.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 9)).padding(.horizontal, 3)
                        .frame(height: 16)
                        .background(activeID == clip.id ? PhotonTheme.accent.opacity(0.3) : PhotonTheme.raised)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay {
                    Rectangle().strokeBorder(
                        activeID == clip.id || (selectedSlotID != nil && selectedSlotID == slot?.id) ? PhotonTheme.accent : PhotonTheme.border,
                        lineWidth: 1
                    )
                }
                .accessibilityLabel("Trigger \(clip.title)")
                .accessibilityIdentifier("photon.slot.\(slot?.id ?? "unknown")")
                .accessibilityValue(activeID == clip.id ? "Playing" : "Stopped")
            } else {
                Rectangle().fill(PhotonTheme.background)
                    .overlay { Rectangle().strokeBorder(PhotonTheme.border) }
                    .accessibilityLabel("Empty clip slot")
            }
        }
    }
}
