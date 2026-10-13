import SwiftUI

struct EffectStackView: View {
    let model: WorkspaceModel
    let scope: InspectorEffectScope
    @State private var dropTarget: String?

    var body: some View {
        VStack(spacing: 1) {
            HStack(spacing: 4) {
                Text("Effects").font(.system(size: 10, weight: .medium))
                Spacer()
                EffectAddMenu(model: model, scope: scope)
            }
            .padding(.horizontal, 4).frame(height: 24)
            PanelBoundary(model: model.effects, retry: { model.reloadEffects(scope: scope) }) { snapshot in
                if snapshot.scope == scope {
                    ForEach(snapshot.effects) { effect in
                        if let definition = model.effectDefinitions.first(where: { $0.id == effect.definitionID }) {
                            EffectInspectorRow(effect: effect, definition: definition, scope: scope, model: model)
                                .disabled(!snapshot.editable)
                                .draggable(effect.id)
                                .dropDestination(for: String.self) { ids, _ in move(ids, before: effect.id, snapshot: snapshot) }
                                    isTargeted: { dropTarget = $0 ? effect.id : nil }
                                .overlay(alignment: .top) {
                                    if dropTarget == effect.id { Rectangle().fill(PhotonTheme.accent).frame(height: 1) }
                                }
                        }
                    }
                    if snapshot.effects.isEmpty {
                        Text("No effects").font(.system(size: 10)).foregroundStyle(PhotonTheme.faint)
                            .padding(4).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Rectangle().fill(dropTarget == "end" ? PhotonTheme.accent : .clear).frame(height: 3)
                            .dropDestination(for: String.self) { ids, _ in move(ids, before: nil, snapshot: snapshot) }
                                isTargeted: { dropTarget = $0 ? "end" : nil }
                    }
                }
            } skeleton: { SkeletonBlock(height: 28) }
        }
        .task(id: scope) { await model.reloadEffects(scope: scope).value }
        .contextMenu { EffectAddItems(model: model, scope: scope) }
    }

    private func move(_ ids: [String], before: String?, snapshot: EffectStackSnapshot) -> Bool {
        guard snapshot.editable, ids.count == 1, let id = ids.first,
              snapshot.effects.contains(where: { $0.id == id }), id != before else { return false }
        model.changeEffect(.moveEffect(scope: scope, effectID: id, beforeID: before), scope: scope)
        dropTarget = nil
        return true
    }
}

struct EffectAddMenu: View {
    let model: WorkspaceModel
    let scope: InspectorEffectScope
    var body: some View {
        Menu { EffectAddItems(model: model, scope: scope) } label: {
            Image(systemName: "plus").font(.system(size: 10)).frame(width: 20)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(model.effectDefinitions.isEmpty || model.effects.value?.scope != scope || model.effects.value?.editable != true)
        .help("Add effect").accessibilityLabel("Add effect")
    }
}

struct EffectAddItems: View {
    let model: WorkspaceModel
    let scope: InspectorEffectScope
    private var categories: [String] {
        model.effectDefinitions.reduce(into: []) { if !$0.contains($1.category) { $0.append($1.category) } }
    }
    var body: some View {
        ForEach(categories, id: \.self) { category in
            Menu(category) {
                ForEach(model.effectDefinitions.filter { $0.category == category }) { definition in
                    Button(definition.name) {
                        model.changeEffect(.addEffect(scope: scope, definitionID: definition.id), scope: scope)
                    }
                    .disabled(model.effects.value?.scope != scope || model.effects.value?.editable != true)
                }
            }
        }
    }
}
