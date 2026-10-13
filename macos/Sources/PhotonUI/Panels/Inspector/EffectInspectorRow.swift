import SwiftUI

struct EffectInspectorRow: View {
    let effect: InspectorEffect
    let definition: EffectDefinition
    let scope: InspectorEffectScope
    let model: WorkspaceModel
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8)).frame(width: 16, height: 26)
                }.help("\(expanded ? "Collapse" : "Expand") \(definition.name)")
                    .accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(definition.name)")
                Button {
                    send(.setEffectEnabled(scope: scope, effectID: effect.id, enabled: !effect.enabled))
                } label: {
                    Image(systemName: effect.enabled ? "circle.fill" : "circle")
                        .font(.system(size: 8)).foregroundStyle(effect.enabled ? PhotonTheme.accent : PhotonTheme.faint)
                        .frame(width: 14, height: 26)
                }.help(effect.enabled ? "Bypass effect" : "Enable effect")
                    .accessibilityLabel("\(definition.name) enabled").accessibilityValue(effect.enabled ? "On" : "Off")
                Text(definition.name).font(.system(size: 11)).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                LiveFader(value: effect.amount, label: "\(definition.name) amount") { change(.amount, $0) }
                    .frame(width: 120)
                Menu {
                    Button(expanded ? "Collapse" : "Expand") { expanded.toggle() }
                    Button("Reset amount") { change(.amount, 0.5) }
                    if definition.parameterLabel != nil { Button("Reset parameters") { change(.secondary, 0.5) } }
                    Divider()
                    Button("Remove effect", role: .destructive, action: remove)
                } label: { Image(systemName: "ellipsis").frame(width: 18) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("\(definition.name) options")
                Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8)).frame(width: 18, height: 26) }
                    .help("Remove \(definition.name)").accessibilityLabel("Remove \(definition.name)")
            }
            .buttonStyle(.plain).padding(.horizontal, 3).frame(height: 28)
            .background(PhotonTheme.raised)
            if expanded {
                VStack(spacing: 1) {
                    EffectParameterRow(title: "Amount", value: effect.amount) { change(.amount, $0) }
                    if let title = definition.parameterLabel {
                        EffectParameterRow(title: title, value: effect.parameter) { change(.secondary, $0) }
                    }
                }
                .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 2)
            }
        }
        .opacity(effect.enabled ? 1 : 0.5)
        .contextMenu {
            Button(effect.enabled ? "Bypass" : "Enable") {
                send(.setEffectEnabled(scope: scope, effectID: effect.id, enabled: !effect.enabled))
            }
            Button("Remove effect", role: .destructive, action: remove)
        }
    }

    private func change(_ parameter: EffectParameter, _ value: Double) {
        send(.setEffectParameter(scope: scope, effectID: effect.id, parameter: parameter, value: value))
    }
    private func remove() { send(.removeEffect(scope: scope, effectID: effect.id)) }
    private func send(_ action: WorkspaceAction) { model.changeEffect(action, scope: scope) }
}
