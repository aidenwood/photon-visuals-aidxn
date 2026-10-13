import PhotonRender
import PhotonUI

enum NativeEffectDefinitions {
    static let all = EffectKind.allCases.map {
        EffectDefinition(id: $0.rawValue, name: $0.name, category: $0.category.rawValue, parameterLabel: $0.paramLabel)
    }
}
