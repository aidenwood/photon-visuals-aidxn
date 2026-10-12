import SwiftUI

/// Native surface hosting and chrome; renderer and GPU lifetimes remain engine-owned.
struct ProgramPreviewSurface: View {
    let snapshot: PreviewSnapshot
    let mapping: Bool
    let surface: ProgramSurfaceFactory?
    let role: PreviewRole
    let fixtureOpacity: Double
    let fixtureBlackout: Bool

    var body: some View {
        GeometryReader { geometry in
            let aspect = CGFloat(snapshot.width) / CGFloat(snapshot.height)
            let width = min(geometry.size.width, geometry.size.height * aspect)
            let height = width / aspect
            ZStack {
                Color.black
                surfaceContent
                    .frame(width: width, height: height)
                    .background { if role == .clip { CheckerboardView() } }
                    .overlay { if mapping { MappingOverlay() } }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomLeading) {
                if role == .clip {
                    Text(surface?.content == .demonstration ? "Demo playback" : "\(snapshot.clip.title) · Preview")
                        .font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
                        .padding(7).background(.black.opacity(0.55))
                }
            }
        }
        .padding(6)
        .background(PhotonTheme.background)
    }

    @ViewBuilder private var surfaceContent: some View {
        if let surface {
            surface.makeView(snapshot, role)
        } else {
            ArtworkView(style: snapshot.clip.artwork)
                .opacity(role == .master ? fixtureOpacity : 1)
                .overlay {
                    if role == .master && fixtureBlackout { Color.black }
                }
        }
    }
}
