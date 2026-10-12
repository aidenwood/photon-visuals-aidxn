import SwiftUI

/// Compact scope tabs shared by inspectors and browsers.
struct PanelTabs<Tab: Hashable>: View {
    let tabs: [Tab]
    let selection: Tab
    let title: (Tab) -> String
    let select: (Tab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                Button { select(tab) } label: {
                    Text(title(tab))
                        .font(.system(size: 10, weight: selection == tab ? .semibold : .regular))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 7)
                        .frame(maxWidth: .infinity)
                        .frame(height: 29)
                        .foregroundStyle(selection == tab ? PhotonTheme.foreground : PhotonTheme.muted)
                        .background(selection == tab ? PhotonTheme.raised : .clear)
                        .overlay(alignment: .bottom) {
                            if selection == tab { Rectangle().fill(PhotonTheme.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .background(PhotonTheme.background)
        .overlay(alignment: .bottom) { Rectangle().fill(PhotonTheme.border).frame(height: 1) }
    }
}
