import SwiftUI

/// Engine-owned cached poster host; never starts live playback for a grid cell.
/// Cache budgets, bounded generation and shared request lifetime stay in the adapter.
public struct ClipPosterFactory: Sendable {
    let makeView: @MainActor @Sendable (MediaClip) -> AnyView

    public init(makeView: @escaping @MainActor @Sendable (MediaClip) -> AnyView) {
        self.makeView = makeView
    }
}

private struct ClipPosterKey: EnvironmentKey {
    static let defaultValue: ClipPosterFactory? = nil
}

extension EnvironmentValues {
    var clipPoster: ClipPosterFactory? {
        get { self[ClipPosterKey.self] }
        set { self[ClipPosterKey.self] = newValue }
    }
}
