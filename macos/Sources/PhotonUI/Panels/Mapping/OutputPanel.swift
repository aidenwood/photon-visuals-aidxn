import SwiftUI

struct OutputPanel: View {
    let model: WorkspaceModel

    var body: some View {
        PanelChrome(title: "Output configuration", detail: "PREVIEW", panelID: .outputConfiguration) {
            PanelBoundary(model: model.outputs, retry: { model.reloadOutputs() }) { snapshot in
                HStack(alignment: .top, spacing: PhotonTheme.panelGap) {
                    ForEach(snapshot.outputs) { output in
                        OutputTile(output: output)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } skeleton: {
                HStack(spacing: PhotonTheme.panelGap) {
                    SkeletonBlock(height: 76)
                    SkeletonBlock(height: 76)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 92)
        }
    }
}
