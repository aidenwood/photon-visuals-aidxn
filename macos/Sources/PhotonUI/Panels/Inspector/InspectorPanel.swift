import SwiftUI

struct InspectorPanel: View {
    let model: WorkspaceModel

    var body: some View {
        PanelChrome(title: "Inspector", detail: model.inspectorScope.rawValue.uppercased(), panelID: .inspector) {
            VStack(spacing: 0) {
                PanelTabs(tabs: InspectorScope.allCases, selection: model.inspectorScope, title: { $0.rawValue }) {
                    model.inspectorScope = $0
                }
                scopeContent.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    @ViewBuilder private var scopeContent: some View {
        switch model.inspectorScope {
        case .clip:
            PanelBoundary(model: model.inspector, retry: { model.reloadInspector() }) { snapshot in
                ScrollView {
                    InspectorContents(model: model, snapshot: snapshot,
                        setOpacity: { model.setOpacity($0, clipID: snapshot.clip.id) },
                        setBlend: { model.setBlendMode($0, clipID: snapshot.clip.id) })
                        .id(snapshot.clip.id)
                }
            } skeleton: { InspectorSkeleton() }
        case .composition:
            CompositionInspector(model: model)
        case .layer:
            LayerInspector(model: model)
        case .column:
            ColumnInspector(model: model)
        case .group:
            PanelEmptyView(symbol: "square.stack.3d.up", title: "No group selected", detail: "Layer groups will appear here when the project supports them.")
        }
    }
}
