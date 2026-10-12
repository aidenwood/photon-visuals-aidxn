import SwiftUI

struct BlendModeControl: View {
    let value: String
    let select: (String) -> Void

    var body: some View {
        ParameterRow(label: "Blend") {
            Picker("Blend mode", selection: Binding(get: { value }, set: { select($0) })) {
                ForEach(["Normal", "Add", "Multiply", "Screen"], id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .labelsHidden().pickerStyle(.menu).controlSize(.small).frame(width: 120)
        }
    }
}
