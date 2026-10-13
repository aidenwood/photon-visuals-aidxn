import SwiftUI

struct PreviewMonitors: View {
    let model: WorkspaceModel
    let surface: ProgramSurfaceFactory?

    var body: some View {
        VStack(spacing: PhotonTheme.panelGap) {
            PreviewPanel(model: model, surface: surface, role: .master).frame(maxHeight: .infinity)
            PreviewPanel(model: model, surface: surface, role: .clip).frame(maxHeight: .infinity)
        }
    }
}
