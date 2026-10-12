// Output topology — screens, slices, and which projector gets what.
//
// Stored **separately from the composition**, because the same show travels to
// a different venue with a completely different rig. Resolume gets this right
// and it matters operationally: you do not want to re-cut a show to re-hang it.
//
// ## The abstraction that makes big rigs work
//
// **A projector is a rectangle inside an output canvas, not "a display."**
// An M4 drives 4 external displays at most, so a 16-projector show runs through
// hardware splitters (Datapath FX4, DisplayPort MST) where one output carries
// four projectors side by side. Model a projector as a display and that rig is
// impossible; model it as a rect inside a canvas and it is ordinary.

import Foundation
import simd

/// Where a screen's pixels actually go.
public enum ScreenTarget: Codable, Sendable, Equatable {
    /// A physical display, by its stable identifier.
    case display(id: UInt32)
    /// An inter-app texture (Syphon on macOS, Spout on Windows).
    case interApp(name: String)
    /// A network stream.
    case ndi(name: String)
    /// Rendered but not sent anywhere — for previewing a mapping offline.
    case virtual
}

/// One output surface: a canvas, and the slices drawn into it.
public struct Screen: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Where this screen's pixels go.
    public var target: ScreenTarget
    /// Canvas size in pixels. On a splitter this is the FULL width of all the
    /// projectors it feeds, not one projector.
    public var width: Int
    public var height: Int
    /// Slices drawn into this canvas — typically one per projector.
    public var slices: [SliceConfig]
    /// Excluded from output without deleting its mapping.
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, target: ScreenTarget,
                width: Int, height: Int, slices: [SliceConfig] = [],
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.target = target
        self.width = max(1, width)
        self.height = max(1, height)
        self.slices = slices
        self.enabled = enabled
    }
}

/// A serialisable slice: which part of the composition lands where on a screen.
public struct SliceConfig: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// Region of the composition sampled, normalised 0..1.
    public var sourceOrigin: SIMD2<Float>
    public var sourceSize: SIMD2<Float>
    /// Output corners in clip space (-1..1), in TL, TR, BR, BL order.
    public var corners: [SIMD2<Float>]
    /// Optional grid subdivision for curved surfaces.
    public var gridColumns: Int?
    public var gridRows: Int?
    /// Soft-edge overlap widths as a fraction of this slice, and the curve.
    public var edgeLeft: Float
    public var edgeRight: Float
    public var edgeTop: Float
    public var edgeBottom: Float
    public var edgeGamma: Float
    /// Per-slice output level, for matching projector brightness.
    public var opacity: Float
    /// Per-channel multiplier, for trimming colour between projectors.
    /// Persisted with the mapping — a venue's colour trim belongs to the rig,
    /// not to the show.
    public var gain: SIMD3<Float>
    /// Per-channel offset, for lifting crushed blacks on a tired lamp.
    public var lift: SIMD3<Float>
    /// Per-slice gamma. 1.0 disables it.
    public var outGamma: Float
    /// Mask polygon in surface space (0..1). Fewer than 3 points = no mask.
    /// Persisted: masking off a doorway or a window belongs to the venue.
    public var mask: [SIMD2<Float>]
    /// Feather width in surface units.
    public var maskFeather: Float
    /// Keep the outside of the polygon instead of the inside.
    public var maskInvert: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String,
                sourceOrigin: SIMD2<Float> = .init(0, 0),
                sourceSize: SIMD2<Float> = .init(1, 1),
                corners: [SIMD2<Float>] = SliceConfig.fullCanvasCorners,
                gridColumns: Int? = nil, gridRows: Int? = nil,
                edgeLeft: Float = 0, edgeRight: Float = 0,
                edgeTop: Float = 0, edgeBottom: Float = 0,
                edgeGamma: Float = 2.2,
                opacity: Float = 1,
                gain: SIMD3<Float> = .init(1, 1, 1),
                lift: SIMD3<Float> = .init(0, 0, 0),
                outGamma: Float = 1,
                mask: [SIMD2<Float>] = [],
                maskFeather: Float = 0.01,
                maskInvert: Bool = false,
                enabled: Bool = true) {
        self.id = id
        self.name = name
        self.sourceOrigin = sourceOrigin
        self.sourceSize = sourceSize
        self.corners = corners.count == 4 ? corners : SliceConfig.fullCanvasCorners
        self.gridColumns = gridColumns
        self.gridRows = gridRows
        self.edgeLeft = edgeLeft
        self.edgeRight = edgeRight
        self.edgeTop = edgeTop
        self.edgeBottom = edgeBottom
        self.edgeGamma = edgeGamma
        self.opacity = opacity
        self.gain = gain
        self.lift = lift
        self.outGamma = outGamma
        self.mask = mask
        self.maskFeather = maskFeather
        self.maskInvert = maskInvert
        self.enabled = enabled
    }

    /// TL, TR, BR, BL — matching `QuadCorners`' index order.
    public static let fullCanvasCorners: [SIMD2<Float>] = [
        .init(-1, 1), .init(1, 1), .init(1, -1), .init(-1, -1),
    ]

    /// Converts to the renderer's slice type.
    public func asOutputSlice() -> OutputSlice {
        let quad = QuadCorners(topLeft: corners[0], topRight: corners[1],
                               bottomRight: corners[2], bottomLeft: corners[3])
        let grid: WarpGrid? = {
            guard let c = gridColumns, let r = gridRows, c > 0, r > 0 else { return nil }
            return WarpGrid(columns: c, rows: r)
        }()
        let surface = WarpSurface(
            corners: quad,
            grid: grid,
            softEdge: SoftEdge(left: edgeLeft, right: edgeRight,
                               top: edgeTop, bottom: edgeBottom, gamma: edgeGamma),
            sourceOrigin: sourceOrigin,
            sourceSize: sourceSize)
        return OutputSlice(surface: surface, opacity: opacity,
                           gain: gain, lift: lift, outGamma: outGamma,
                           mask: mask, maskFeather: maskFeather, maskInvert: maskInvert)
    }
}

/// The whole output mapping for a venue.
public struct OutputTopology: Codable, Sendable {
    /// Format version, so a mapping saved today still loads later.
    public var version: Int
    public var name: String
    public var screens: [Screen]

    public init(version: Int = 1, name: String = "Untitled", screens: [Screen] = []) {
        self.version = version
        self.name = name
        self.screens = screens
    }

    /// Slices that should actually render, flattened across enabled screens.
    public func activeSlices() -> [OutputSlice] {
        screens
            .filter(\.enabled)
            .flatMap(\.slices)
            .filter(\.enabled)
            .map { $0.asOutputSlice() }
    }

    /// A single full-canvas screen — what an operator who has mapped nothing
    /// should still get, rather than a black output.
    public static func singleScreen(width: Int = 1920, height: Int = 1080) -> OutputTopology {
        OutputTopology(name: "Default", screens: [
            Screen(name: "Main", target: .display(id: 0),
                   width: width, height: height,
                   slices: [SliceConfig(name: "Full")]),
        ])
    }

    /// A splitter rig: one wide canvas carrying `count` projectors side by side,
    /// each with soft-edge overlap into its neighbour.
    ///
    /// This is the case the "rect inside a canvas" abstraction exists for — it
    /// is how a show exceeds the machine's display limit.
    public static func splitter(projectors count: Int,
                                projectorWidth: Int = 1920,
                                height: Int = 1080,
                                overlapFraction: Float = 0.15) -> OutputTopology {
        precondition(count >= 1, "a rig needs at least one projector")
        let totalWidth = projectorWidth * count
        let step: Float = 2.0 / Float(count)   // clip space spans -1...1

        let slices = (0..<count).map { i -> SliceConfig in
            let x0 = -1 + step * Float(i)
            let x1 = x0 + step
            // Each projector samples its share of the composition, widened by
            // the overlap so neighbours have something to blend with.
            let srcW = 1.0 / Float(count)
            let srcX = srcW * Float(i)
            return SliceConfig(
                name: "Projector \(i + 1)",
                sourceOrigin: .init(srcX, 0),
                sourceSize: .init(srcW, 1),
                corners: [.init(x0, 1), .init(x1, 1), .init(x1, -1), .init(x0, -1)],
                edgeLeft: i > 0 ? overlapFraction : 0,
                edgeRight: i < count - 1 ? overlapFraction : 0)
        }
        return OutputTopology(name: "\(count)-projector splitter", screens: [
            Screen(name: "Splitter out", target: .display(id: 0),
                   width: totalWidth, height: height, slices: slices),
        ])
    }

    // MARK: - Persistence

    /// Saves the mapping. Separate file from the composition, deliberately.
    public func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Loads a mapping.
    public static func read(from url: URL) throws -> OutputTopology {
        try JSONDecoder().decode(OutputTopology.self, from: Data(contentsOf: url))
    }
}
