import SwiftUI

/// Inject an engine-owned native view without importing Metal/FFI into PhotonUI.
/// Its presentation clock and GPU leases remain owned by the engine.
public struct ProgramSurfaceFactory {
    let makeView: @MainActor (PreviewSnapshot, PreviewRole) -> AnyView
    let makeMappingView: (@MainActor (PreviewSnapshot, MappingQuad) -> AnyView)?
    public let content: Content

    public enum Content { case workspace, demonstration }

    public init(content: Content = .workspace,
                mappingView: (@MainActor (PreviewSnapshot, MappingQuad) -> AnyView)? = nil,
                makeView: @escaping @MainActor (PreviewSnapshot, PreviewRole) -> AnyView) {
        self.content = content
        self.makeView = makeView
        self.makeMappingView = mappingView
    }
}
