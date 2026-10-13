import Foundation

/// Display descriptors supplied by the native EffectKind adapter, not a second engine registry.
public struct EffectDefinition: Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let category: String
    public let parameterLabel: String?
    public init(id: Int32, name: String, category: String, parameterLabel: String?) {
        self.id = id; self.name = name; self.category = category; self.parameterLabel = parameterLabel
    }
}

public enum InspectorEffectScope: Hashable, Sendable {
    case composition, layer(String), clip(String)
}

public enum EffectParameter: String, Sendable { case amount, secondary }

public struct InspectorEffect: Identifiable, Sendable {
    public let id: String
    public let definitionID: Int32
    public var amount: Double
    public var parameter: Double
    public var enabled: Bool
    public init(id: String, definitionID: Int32, amount: Double = 0.5, parameter: Double = 0.5, enabled: Bool = true) {
        self.id = id; self.definitionID = definitionID
        self.amount = amount; self.parameter = parameter; self.enabled = enabled
    }
}

public struct EffectStackSnapshot: Sendable {
    public let scope: InspectorEffectScope
    public let effects: [InspectorEffect]
    public let editable: Bool
    public init(scope: InspectorEffectScope, effects: [InspectorEffect], editable: Bool = false) {
        self.scope = scope; self.effects = effects; self.editable = editable
    }
    public func validated() throws -> Self {
        guard Set(effects.map(\.id)).count == effects.count,
              effects.allSatisfy({ !$0.id.isEmpty && $0.amount.isFinite && $0.parameter.isFinite
                  && (0...1).contains($0.amount) && (0...1).contains($0.parameter) }) else {
            throw PanelIssue(title: "Effects unavailable", message: "Invalid effect parameters received.")
        }
        return self
    }
}
