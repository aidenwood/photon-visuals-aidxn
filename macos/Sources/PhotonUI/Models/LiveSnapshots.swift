import Foundation

public struct DeckDescriptor: Identifiable, Sendable {
    public let id: String
    public let title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct ClipSlotSnapshot: Identifiable, Sendable {
    public let id: String
    public let column: Int
    public let clip: MediaClip?
    public init(id: String, column: Int, clip: MediaClip?) {
        self.id = id; self.column = column; self.clip = clip
    }
}

public struct LayerSnapshot: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let opacity: Double
    public let bypass: Bool
    public let solo: Bool
    public let activeClipID: String?
    public let slots: [ClipSlotSnapshot]
    private let slotsByColumn: [Int: ClipSlotSnapshot]

    public init(
        id: String, title: String, opacity: Double, bypass: Bool, solo: Bool,
        activeClipID: String?, slots: [ClipSlotSnapshot]
    ) {
        self.id = id; self.title = title; self.opacity = opacity
        self.bypass = bypass; self.solo = solo; self.activeClipID = activeClipID; self.slots = slots
        self.slotsByColumn = Dictionary(slots.map { ($0.column, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func slot(in column: Int) -> ClipSlotSnapshot? { slotsByColumn[column] }
}

public struct LayerStackSnapshot: Sendable {
    public let layers: [LayerSnapshot]
    public let columns: Int
    public let deckID: String?
    public let decks: [DeckDescriptor]
    public init(layers: [LayerSnapshot], columns: Int, deckID: String? = nil, decks: [DeckDescriptor] = []) {
        self.layers = layers; self.columns = columns; self.deckID = deckID; self.decks = decks
    }

    public func validated() throws -> Self {
        let ids = layers.map(\.id)
        let slotIDs = layers.flatMap { $0.slots.map(\.id) }
        let deckIDs = decks.map(\.id)
        guard columns > 0, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty }),
              Set(deckIDs).count == deckIDs.count, deckIDs.allSatisfy({ !$0.isEmpty }),
              deckID == nil || deckIDs.contains(deckID ?? ""),
              Set(slotIDs).count == slotIDs.count, slotIDs.allSatisfy({ !$0.isEmpty }),
              layers.allSatisfy({ layer in
                  layer.opacity.isFinite && (0...1).contains(layer.opacity) &&
                  layer.slots.allSatisfy({ (0..<columns).contains($0.column) && ($0.clip?.id.isEmpty != true) }) &&
                  Set(layer.slots.map(\.column)).count == layer.slots.count &&
                  layer.activeClipID?.isEmpty != true
              }) else {
            throw PanelIssue(title: "Layers unavailable", message: "The layer data is invalid.")
        }
        return self
    }
}

public struct MasterSnapshot: Sendable {
    public let opacity: Double
    public let blackout: Bool
    public init(opacity: Double, blackout: Bool) { self.opacity = opacity; self.blackout = blackout }

    public func validated() throws -> Self {
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw PanelIssue(title: "Master unavailable", message: "The master value is invalid.")
        }
        return self
    }
}

public enum PreviewRole: Sendable {
    case clip, master
}
