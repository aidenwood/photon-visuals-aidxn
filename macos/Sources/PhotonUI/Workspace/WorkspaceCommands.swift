import SwiftUI

public struct WorkspaceCommands: Commands {
    let model: WorkspaceModel
    public init(model: WorkspaceModel) { self.model = model }

    public var body: some Commands {
        CommandMenu("Workspace") {
            Button("Commands…") { model.isCommandPalettePresented = true }
                .keyboardShortcut("k")
            Divider()
            Button("Perform") { model.switchPersona(.perform) }.keyboardShortcut("1").disabled(model.performanceLocked)
            Button("Map") { model.switchPersona(.map) }.keyboardShortcut("2").disabled(model.performanceLocked)
            Button("Toggle Monitor Layout") {
                if model.persona == .perform {
                    model.switchTemplate(model.template == .perform ? .preview : .perform)
                } else {
                    model.switchTemplate(model.template == .mapping ? .mappingWide : .mapping)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(model.performanceLocked)
            Divider()
            Button("Reload Library") { model.reloadLibrary() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandMenu("Transport") {
            Button("Blackout") { model.toggleBlackout() }
                .keyboardShortcut("b", modifiers: [.command, .option])
            Button(model.transport.value?.isPlaying == true ? "Pause" : "Play") { model.togglePlayback() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.transport.value == nil || model.transport.phase.isLoading)
        }
    }
}
