/// Stable editor panel identifiers. Independent of engine node/resource IDs.
public enum WorkspacePanelID: Int, Codable, Sendable {
    case clipMatrix = 100
    case transport = 101
    case compositionMonitor = 102
    case clipMonitor = 103
    case inspector = 104
    case browser = 105
    case outputCanvas = 106
    case outputConfiguration = 107
    case masterStrip = 108

    var accessibilityIdentifier: String { "photon.panel.\(rawValue)" }
}
