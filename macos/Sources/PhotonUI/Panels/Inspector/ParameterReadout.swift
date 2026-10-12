import SwiftUI

struct ParameterReadout: View {
    let label: String
    let value: String

    var body: some View {
        ParameterRow(label: label) {
            Text(value).monospacedDigit()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .frame(minWidth: 72, alignment: .trailing)
                .background(PhotonTheme.raised, in: RoundedRectangle(cornerRadius: 5))
        }
        .font(.system(size: 11))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}
