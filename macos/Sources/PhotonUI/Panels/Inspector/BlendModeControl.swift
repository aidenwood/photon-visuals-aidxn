import SwiftUI

struct BlendModeControl: View {
    let value: String
    let select: (String) -> Void

    var body: some View {
        ParameterRow(label: "Blend") {
            Menu {
                ForEach(["Normal", "Add", "Multiply", "Screen"], id: \.self) { mode in
                    Button { select(mode) } label: {
                        if mode == value { Label(mode, systemImage: "checkmark") }
                        else { Text(mode) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(value).font(.system(size: 11))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }
                .padding(.horizontal, 6).frame(height: PhotonTheme.controlHeight)
                .background(PhotonTheme.raised, in: Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 120)
            .accessibilityLabel("Blend mode").accessibilityValue(value)
        }
    }
}
