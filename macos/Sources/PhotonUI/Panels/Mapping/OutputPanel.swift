import SwiftUI

struct OutputPanel: View {
    let model: WorkspaceModel

    var body: some View {
        PanelChrome(title: "Output configuration", detail: "PREVIEW", panelID: .outputConfiguration) {
            PanelBoundary(model: model.outputs, retry: { model.reloadOutputs() }) { snapshot in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(snapshot.outputs) { output in
                        OutputTile(output: output)
                    }
                }
                .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } skeleton: {
                HStack(spacing: 12) {
                    SkeletonBlock(height: 116, radius: 8)
                    SkeletonBlock(height: 116, radius: 8)
                }
                .padding(16).frame(maxHeight: .infinity, alignment: .top)
            }
            .frame(height: 222)
        }
    }
}
