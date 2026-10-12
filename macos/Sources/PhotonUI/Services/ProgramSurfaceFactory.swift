import SwiftUI

/// Inject an engine-owned native view without importing Metal/FFI into PhotonUI.
/// Its presentation clock and GPU leases remain owned by the engine.
public struct ProgramSurfaceFactory {
    let makeView: @MainActor (PreviewSnapshot, PreviewRole) -> AnyView
    public let content: Content

    public enum Content { case workspace, demonstration }

    public init(content: Content = .workspace, makeView: @escaping @MainActor (PreviewSnapshot, PreviewRole) -> AnyView) {
        self.content = content
        self.makeView = makeView
    }
}
