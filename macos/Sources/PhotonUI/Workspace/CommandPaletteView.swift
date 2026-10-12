import SwiftUI

struct CommandPaletteView: View {
    let model: WorkspaceModel
    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    private var commands: [(String, String, () -> Void)] {
        var items: [(String, String, () -> Void)] = [
            ("Perform workspace", "play.rectangle", { model.switchPersona(.perform) }),
            ("Map workspace", "viewfinder", { model.switchPersona(.map) }),
            ("Perform layout", "rectangle.split.3x1", { model.switchPersona(.perform); model.switchTemplate(.perform) }),
            ("Big Monitor layout", "rectangle", { model.switchPersona(.perform); model.switchTemplate(.preview) }),
            ("Many Layers layout", "rectangle.split.3x3", { model.switchPersona(.perform); model.switchTemplate(.manyLayers) }),
            ("Toggle layout lock", "lock", { model.performanceLocked.toggle() }),
            (model.isBlackedOut ? "Release blackout" : "Blackout", "power", { model.toggleBlackout() }),
            (model.transport.value?.isPlaying == true ? "Pause preview" : "Play preview", "playpause", { model.togglePlayback() }),
            ("Reload library", "arrow.clockwise", { model.reloadLibrary() }),
            ("Reload preview", "arrow.clockwise", { model.reloadPreview() }),
            ("Reload composition monitor", "arrow.clockwise", { model.reloadMasterPreview() }),
            ("Reload inspector", "arrow.clockwise", { model.reloadInspector() }),
        ]
        #if DEBUG
        items += [
            ("Fail clip preview", "exclamationmark.triangle", { model.preview.simulateFailure() }),
            ("Fail composition monitor", "exclamationmark.triangle", { model.masterPreview.simulateFailure() }),
            ("Fail layers panel", "exclamationmark.triangle", { model.layers.simulateFailure() }),
        ]
        #endif
        return items.filter { query.isEmpty || $0.0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(PhotonTheme.accent)
                TextField("Find a command…", text: $query)
                    .textFieldStyle(.plain).focused($focused)
                    .onSubmit {
                        guard commands.indices.contains(selectedIndex) else { return }
                        commands[selectedIndex].2()
                        dismiss()
                    }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(max(0, commands.count - 1), selectedIndex + 1)
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(0, selectedIndex - 1)
                        return .handled
                    }
                Button("Esc") { dismiss() }.buttonStyle(.plain).foregroundStyle(PhotonTheme.faint)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider().overlay(PhotonTheme.border)
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(commands.enumerated()), id: \.element.0) { index, command in
                        let (title, symbol, action) = command
                        Button { action(); dismiss() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: symbol).frame(width: 16).foregroundStyle(PhotonTheme.muted)
                                Text(title)
                                Spacer()
                                Image(systemName: "return").foregroundStyle(PhotonTheme.faint)
                            }
                            .padding(12).contentShape(Rectangle())
                            .background(index == selectedIndex ? PhotonTheme.raised : .clear, in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                    if commands.isEmpty {
                        Text("No matching commands").foregroundStyle(PhotonTheme.muted).padding(24)
                    }
                }
                .padding(10)
            }
            .onChange(of: selectedIndex) { _, index in proxy.scrollTo(index, anchor: .center) }
            }
        }
        .font(.system(size: 12)).foregroundStyle(PhotonTheme.foreground)
        .frame(width: 480, height: 340)
        .background(PhotonTheme.panel)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
    }
}
