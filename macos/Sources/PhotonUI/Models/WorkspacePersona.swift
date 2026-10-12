public enum WorkspacePersona: String, CaseIterable, Identifiable, Sendable {
    case perform = "Perform"
    case map = "Map"
    public var id: Self { self }
    public var symbol: String { self == .perform ? "play.rectangle" : "viewfinder" }
}

public enum WorkspaceTemplate: String, CaseIterable, Identifiable, Codable, Sendable {
    case perform = "Perform"
    case preview = "Big Monitor"
    case manyLayers = "Many Layers"
    case mapping = "Mapping"
    case mappingWide = "Wide Canvas"
    public var id: Self { self }

    public static func available(for persona: WorkspacePersona) -> [Self] {
        persona == .perform ? [.perform, .preview, .manyLayers] : [.mapping, .mappingWide]
    }

    var gridFraction: Double {
        switch self {
        case .preview: 0.34
        case .manyLayers: 0.62
        default: 0.49
        }
    }
}
