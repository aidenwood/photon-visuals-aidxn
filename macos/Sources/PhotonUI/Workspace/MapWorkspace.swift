import SwiftUI

struct MapWorkspace: View {
    let model: WorkspaceModel
    let surface: ProgramSurfaceFactory?

    var body: some View {
        HStack(alignment: .top, spacing: PhotonTheme.panelGap) {
            VStack(spacing: PhotonTheme.panelGap) {
                HStack(spacing: 6) {
                    Text("Slice 01 · Corner pin").font(.system(size: 10, weight: .medium))
                    Text("Drag a corner to keystone").font(.system(size: 10)).foregroundStyle(PhotonTheme.muted)
                    Spacer()
                    Button("Reset corners") { model.mappingQuad = .identity }
                        .buttonStyle(.plain).foregroundStyle(PhotonTheme.accent)
                }
                .padding(.horizontal, 4).frame(height: 24).background(PhotonTheme.raised)
                PreviewPanel(model: model, surface: surface, role: .master)
                    .frame(maxHeight: .infinity)
                OutputPanel(model: model)
            }
            InspectorPanel(model: model).frame(width: model.template == .mappingWide ? 310 : 390)
        }
    }
}
