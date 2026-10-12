// Bridges the engine's Metal view into PhotonUI's `ProgramSurfaceFactory`.
//
// This is the only file that knows about both sides. PhotonUI stays free of
// Metal and FFI; the engine stays free of SwiftUI layout concerns.

import SwiftUI
import PhotonUI

/// SwiftUI wrapper around the engine's Metal view.
private struct ProgramSurfaceRepresentable: NSViewRepresentable {
    let role: SurfaceRole

    func makeNSView(context: Context) -> NSView {
        // If Metal is unavailable the panel must degrade, not crash — a
        // failed preview can never be allowed to take the app down mid-show.
        guard let view = ProgramMetalView.make(role: role) else {
            let fallback = NSView()
            fallback.wantsLayer = true
            fallback.layer?.backgroundColor = NSColor.black.cgColor
            return fallback
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

public extension ProgramSurfaceFactory {
    /// The live engine surface. Pass to `PhotonWorkspace(model:programSurface:)`.
    ///
    /// Without this the preview panels fall back to static artwork — which is
    /// why an un-injected preview monitor looks like it "doesn't work".
    static func engine() -> ProgramSurfaceFactory {
        ProgramSurfaceFactory(content: .demonstration) { _, role in
            AnyView(
                ProgramSurfaceRepresentable(
                    role: role == .master ? .master : .clip
                )
            )
        }
    }
}
