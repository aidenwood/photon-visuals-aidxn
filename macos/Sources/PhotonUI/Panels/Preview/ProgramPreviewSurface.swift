import SwiftUI

/// Native surface hosting and chrome; renderer and GPU lifetimes remain engine-owned.
struct ProgramPreviewSurface: View {
    let snapshot: PreviewSnapshot
    let mapping: Bool
    let surface: ProgramSurfaceFactory?
    let role: PreviewRole
    @Binding var mappingQuad: MappingQuad
    let fixtureOpacity: Double
    let fixtureBlackout: Bool

    var body: some View {
        GeometryReader { geometry in
            let aspect = CGFloat(snapshot.width) / CGFloat(snapshot.height)
            // Corner handles are focus targets and need room outside the canvas.
            let inset: CGFloat = mapping ? 24 : 0
            let width = max(1, min(geometry.size.width - inset, (geometry.size.height - inset) * aspect))
            let height = width / aspect
            ZStack {
                Color.black
                surfaceContent
                    .frame(width: width, height: height)
                    .background { if role == .clip { CheckerboardView() } }
                    .overlay { if mapping { MappingOverlay(quad: $mappingQuad) } }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomLeading) {
                if role == .clip {
                    Text(surface?.content == .demonstration ? "Demo playback" : "\(snapshot.clip.title) · Preview")
                        .font(.system(size: 9)).foregroundStyle(PhotonTheme.muted)
                        .padding(PhotonTheme.contentInset).background(.black.opacity(0.55))
                }
            }
        }
        .background(PhotonTheme.background)
    }

    @ViewBuilder private var surfaceContent: some View {
        if let surface {
            if mapping, let makeMappingView = surface.makeMappingView {
                makeMappingView(snapshot, mappingQuad)
            } else {
                surface.makeView(snapshot, role)
            }
        } else {
            ArtworkView(style: snapshot.clip.artwork)
                .opacity(role == .master ? fixtureOpacity : 1)
                .overlay {
                    if role == .master && fixtureBlackout { Color.black }
                }
        }
    }
}
