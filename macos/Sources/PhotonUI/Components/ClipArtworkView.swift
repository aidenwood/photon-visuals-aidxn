import SwiftUI

struct ClipArtworkView: View {
    let clip: MediaClip
    @Environment(\.clipPoster) private var poster

    var body: some View {
        if let poster {
            poster.makeView(clip)
        } else {
            ArtworkView(style: clip.artwork)
        }
    }
}
