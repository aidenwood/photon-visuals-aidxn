import SwiftUI
import PhotonUI
import PhotonRenderSurface
import PhotonCoreBridge
import OSLog

@main
struct PhotonApp: App {
    @NSApplicationDelegateAdaptor(PhotonAppDelegate.self) private var delegate
    @State private var workspace: WorkspaceModel

    init() {
        let model = WorkspaceModel()
        do {
            _ = try PhotonCoreABI.validate()
        } catch {
            // Reject core use before passing structs; keep the editor and demo
            // available rather than turning one integration failure into a crash.
            model.integrationIssue = PanelIssue(title: "Core unavailable", message: String(describing: error))
            Logger(subsystem: "com.aidxn.photon.preview", category: "core").error("Core ABI validation failed")
        }
        _workspace = State(initialValue: model)
    }

    var body: some Scene {
        Window("Photon", id: "workspace") {
            PhotonWorkspace(model: workspace, programSurface: .engine())
        }
        .defaultSize(width: 1460, height: 960)
        .windowResizability(.contentMinSize)
        .commands { WorkspaceCommands(model: workspace) }
    }
}
