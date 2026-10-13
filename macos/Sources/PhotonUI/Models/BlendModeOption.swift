/// One blend mode the engine can actually composite with.
///
/// Identified by the engine's `BlendMode` raw value, exactly as
/// ``EffectDefinition`` carries an `EffectKind` raw value. PhotonUI never
/// imports the render package, so the catalogue is **injected** by the app
/// layer from `BlendMode.allCases` rather than written out here.
///
/// That injection is the whole point. A hand-written list of mode names in the
/// UI is a second definition of the enum, and the two drift: an earlier build
/// shipped a four-name list against an eleven-case enum, so seven modes were
/// unreachable and one of them crashed on selection. There is no list here to
/// go stale — if the engine gains a mode it appears in every menu, and if it
/// loses one the menu loses it in the same build.
public struct BlendModeOption: Identifiable, Hashable, Sendable {
    /// The engine's `BlendMode.rawValue`. The only identity that crosses the seam.
    public let id: Int32
    /// The engine's own `BlendMode.name`, never a UI synonym for it.
    public let name: String

    public init(id: Int32, name: String) {
        self.id = id
        self.name = name
    }

    /// The composite default — `BlendMode.over`, raw value 0. Used when a layer
    /// has never been given a mode, and as the label of last resort when the
    /// catalogue has not been injected (previews, unit checks).
    public static let defaultID: Int32 = 0
}

public extension Array where Element == BlendModeOption {
    /// The display name for a stored mode id.
    ///
    /// An id with no matching option renders as its number rather than as some
    /// other mode's name. An operator seeing `Blend 7` knows something is
    /// wrong; an operator seeing `Over` when the engine is doing something else
    /// does not, and that is the failure this whole type exists to prevent.
    func name(for id: Int32) -> String {
        first { $0.id == id }?.name ?? "Blend \(id)"
    }
}
