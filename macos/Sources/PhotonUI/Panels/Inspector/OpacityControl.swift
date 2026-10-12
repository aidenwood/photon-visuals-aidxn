import SwiftUI

struct OpacityControl: View {
    let value: Double
    let commit: (Double) -> Void
    var label = "Opacity"

    var body: some View {
        ParameterRow(label: label) {
            LiveFader(value: value, label: label, change: commit)
        }
        .font(.system(size: 11))
    }
}
