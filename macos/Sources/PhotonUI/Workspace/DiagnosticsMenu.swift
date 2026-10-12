#if DEBUG
import SwiftUI

struct DiagnosticsMenu: View {
    let model: WorkspaceModel

    var body: some View {
        Menu {
            Button("Fail library") { model.library.simulateFailure() }
            Button("Fail preview") { model.preview.simulateFailure() }
            Button("Fail master preview") { model.masterPreview.simulateFailure() }
            Button("Fail layers") { model.layers.simulateFailure() }
            Button("Fail master controls") { model.master.simulateFailure() }
            Button("Fail inspector") { model.inspector.simulateFailure() }
            Button("Fail outputs") { model.outputs.simulateFailure() }
            Button("Fail transport") { model.transport.simulateFailure() }
            Button("Fail metrics") { model.telemetry.simulateFailure() }
            Divider()
            Button("Reload all panels") { Task { await model.start() } }
        } label: {
            Image(systemName: "ladybug").foregroundStyle(PhotonTheme.faint)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Panel recovery diagnostics")
        .accessibilityLabel("Panel recovery diagnostics")
    }
}
#endif
