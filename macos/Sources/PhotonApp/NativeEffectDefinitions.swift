import PhotonRender
import PhotonUI

enum NativeEffectDefinitions {
    static let all = EffectKind.allCases.map {
        EffectDefinition(id: $0.rawValue, name: $0.name, category: $0.category.rawValue, parameterLabel: $0.paramLabel)
    }
}

/// The blend modes the renderer can actually composite with, published to the
/// UI the same way effects are.
///
/// Derived from `BlendMode.allCases` and `BlendMode.name` — never a list typed
/// out again here. The enum and a hand-written UI copy of it drifted once
/// already: the copy was missing `subtract`, so every id above it pointed at
/// the wrong mode and selecting `Darken` ran off the end. There is nothing
/// here left to drift.
enum NativeBlendModes {
    static let all = BlendMode.allCases.map { BlendModeOption(id: $0.rawValue, name: $0.name) }
}
