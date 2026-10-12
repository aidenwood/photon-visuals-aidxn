import SwiftUI

struct PreviewPanel: View {
    let model: WorkspaceModel
    let surface: ProgramSurfaceFactory?
    var role: PreviewRole = .clip

    private var panel: PanelModel<PreviewSnapshot> {
        role == .master ? model.masterPreview : model.preview
    }

    var body: some View {
        PanelChrome(
            title: model.persona == .map ? "Mapping canvas" : (role == .master ? "Composition monitor" : "Preview monitor"),
            detail: surface?.content == .demonstration ? "DEMO" : dimensions,
            panelID: model.persona == .map ? .outputCanvas : (role == .master ? .compositionMonitor : .clipMonitor)
        ) {
            PanelBoundary(model: panel, retry: retry) { snapshot in
                ProgramPreviewSurface(
                    snapshot: snapshot, mapping: model.persona == .map, surface: surface, role: role,
                    fixtureOpacity: model.master.value?.opacity ?? 1,
                    fixtureBlackout: model.master.value?.blackout ?? false
                )
            } skeleton: {
                PreviewSkeleton()
            }
        }
    }

    private var dimensions: String {
        guard let snapshot = panel.value else { return "—" }
        return "\(snapshot.width) × \(snapshot.height)"
    }

    private func retry() {
        if role == .master { model.reloadMasterPreview() } else { model.reloadPreview() }
    }
}
