import SwiftUI

struct PerformWorkspace: View {
    let model: WorkspaceModel
    let surface: ProgramSurfaceFactory?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 8) {
                ClipMatrixPanel(model: model)
                    .frame(height: geometry.size.height * model.template.gridFraction)
                TransportBar(model: model)
                HStack(alignment: .top, spacing: 8) {
                    PreviewMonitors(model: model, surface: surface)
                        .frame(width: model.template == .preview ? min(420, geometry.size.width * 0.3) : 260)
                    InspectorPanel(model: model).frame(maxWidth: .infinity, maxHeight: .infinity)
                    BrowserPanel(model: model).frame(width: 260)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(10)
    }
}
