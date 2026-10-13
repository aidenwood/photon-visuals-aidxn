import SwiftUI
import PhotonUI

struct LocalClipPoster: View {
    let clip: MediaClip
    let catalog: LocalMediaCatalog
    @State private var image: CGImage?
    @State private var loading = true

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Image(systemName: loading ? "film" : "photo.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .task(id: clip.assetID) {
            image = nil
            loading = true
            let poster = await catalog.poster(assetID: clip.assetID)
            guard !Task.isCancelled else { return }
            image = poster
            loading = false
        }
        .accessibilityLabel("Poster for \(clip.title)")
        .help(loading ? "Loading \(clip.title)" : (image == nil ? "Thumbnail unavailable: \(clip.title)" : clip.title))
        .allowsHitTesting(false)
    }
}
