import SwiftUI

struct ParameterReadout: View {
    let label: String
    let value: String

    var body: some View {
        ParameterRow(label: label) {
            Text(value).monospacedDigit()
                .padding(.horizontal, 6).frame(minHeight: PhotonTheme.controlHeight)
                .frame(minWidth: 72, alignment: .trailing)
                .background(PhotonTheme.raised, in: Rectangle())
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
