import CoreTransferable
import UniformTypeIdentifiers

public extension UTType {
    /// Drag type for an effect pulled out of the browser.
    ///
    /// Deliberately not `String`: the chain already reorders itself by dragging
    /// an effect *instance* ID as plain text, and a browser drag that also
    /// arrived as text would be accepted by the reorder drop and silently do
    /// nothing. Two different gestures, two different types.
    static let photonEffectDefinition = UTType(exportedAs: "com.aidxn.photon.effect-definition")
}

/// What travels from a browser row to a chain: the engine's `EffectKind` raw
/// value, nothing else. Amount, parameter and enable are the chain's defaults —
/// the drop decides *which* effect and *where*, never its settings.
public struct EffectDragPayload: Codable, Sendable, Transferable {
    public let definitionID: Int32

    public init(definitionID: Int32) { self.definitionID = definitionID }

    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .photonEffectDefinition)
    }
}
