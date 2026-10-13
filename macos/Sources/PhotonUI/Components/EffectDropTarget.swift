import SwiftUI

/// Accepts an effect dragged out of the browser and appends it to `scope`.
///
/// The whole target is outlined rather than a line drawn between two rows,
/// because this drop appends — it has no insertion point to promise. The line
/// indicator belongs to reordering inside the chain, where it is honest.
struct EffectDropTarget: ViewModifier {
    let model: WorkspaceModel
    let scope: InspectorEffectScope
    let label: String
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .dropDestination(for: EffectDragPayload.self) { payload, _ in
                // Only ever one effect per drag, and only one the engine
                // actually published. An unknown ID is refused rather than
                // added as a row that would render nothing.
                guard payload.count == 1, let dropped = payload.first,
                      model.effectDefinitions.contains(where: { $0.id == dropped.definitionID })
                else { return false }
                model.addEffect(definitionID: dropped.definitionID, scope: scope)
                return true
            } isTargeted: { targeted = $0 }
            .overlay {
                if targeted {
                    Rectangle()
                        .strokeBorder(PhotonTheme.accent, lineWidth: 2)
                        .background(PhotonTheme.accent.opacity(0.12))
                        .allowsHitTesting(false)
                }
            }
            .accessibilityHint("Drop target: adds an effect to \(label)")
    }
}

extension View {
    /// Makes this view accept an effect dragged from the browser.
    func effectDropTarget(model: WorkspaceModel, scope: InspectorEffectScope, label: String) -> some View {
        modifier(EffectDropTarget(model: model, scope: scope, label: label))
    }
}
