import SwiftUI

public struct PhotonWorkspace: View {
    @Bindable private var model: WorkspaceModel
    private let programSurface: ProgramSurfaceFactory?
    private let clipPoster: ClipPosterFactory?

    public init(model: WorkspaceModel, programSurface: ProgramSurfaceFactory? = nil, clipPoster: ClipPosterFactory? = nil) {
        self.model = model
        self.programSurface = programSurface
        self.clipPoster = clipPoster
    }

    public var body: some View {
        VStack(spacing: 0) {
            WorkspaceHeader(model: model)
            Group {
                if model.persona == .perform {
                    PerformWorkspace(model: model, surface: programSurface)
                } else {
                    MapWorkspace(model: model, surface: programSurface)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PerformanceBar(model: model)
        }
        .font(.system(size: 12))
        .foregroundStyle(PhotonTheme.foreground)
        .background(PhotonTheme.background)
        .preferredColorScheme(.dark)
        .frame(minWidth: 1100, minHeight: 780)
        .sheet(isPresented: $model.isCommandPalettePresented) {
            CommandPaletteView(model: model)
        }
        .task { await model.start() }
        .environment(\.clipPoster, clipPoster)
    }
}
