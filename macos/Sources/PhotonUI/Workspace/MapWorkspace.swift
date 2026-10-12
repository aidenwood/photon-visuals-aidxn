import SwiftUI

struct MapWorkspace: View {
    let model: WorkspaceModel
    let surface: ProgramSurfaceFactory?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                PreviewPanel(model: model, surface: surface, role: .master)
                    .frame(maxHeight: .infinity)
                OutputPanel(model: model)
            }
            InspectorPanel(model: model).frame(width: model.template == .mappingWide ? 310 : 390)
        }
        .padding(10)
    }
}
