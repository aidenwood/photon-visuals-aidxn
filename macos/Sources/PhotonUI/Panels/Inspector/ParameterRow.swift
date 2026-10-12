import SwiftUI

/// One line per parameter; the label column aligns across the whole inspector.
struct ParameterRow<Control: View>: View {
    let label: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                .lineLimit(1).frame(width: 76, alignment: .trailing)
            control().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 27)
    }
}
