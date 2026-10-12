// The clip grid — columns × layers, and how triggering actually behaves.
//
// Resolume's model, because an operator moving between tools should not have to
// relearn it:
//
//  - A **column** fires every clip in it at once. That is the primary gesture;
//    a column is a "look", not a list.
//  - A **cell** fires one clip on one layer.
//  - Launches are **quantised** engine-side, not by the caller, so every
//    surface — grid click, MIDI pad, OSC, remote — lands on the same beat.
//
// Quantisation is why this owns a pending queue rather than acting immediately.
// A trigger at beat 3.9 with bar quantisation must fire at beat 4.0, and until
// then the cell shows as *armed* — an operator watching the grid needs to see
// that their press registered, or they press again.
//
// Musical time is injected rather than owned, so this stays testable without a
// running clock and so the authoritative clock can live in `photon-core`.

import Foundation

/// Launch quantisation, in musical time.
public enum Quantise: Sendable, Equatable, CaseIterable {
    case immediate
    case beat
    case bar
    case twoBars
    case fourBars

    public var beats: Double? {
        switch self {
        case .immediate: return nil
        case .beat: return 1
        case .bar: return 4
        case .twoBars: return 8
        case .fourBars: return 16
        }
    }

    public var name: String {
        switch self {
        case .immediate: return "Immediate"
        case .beat: return "1 Beat"
        case .bar: return "1 Bar"
        case .twoBars: return "2 Bars"
        case .fourBars: return "4 Bars"
        }
    }
}

/// One cell in the grid.
public struct Cell: Sendable, Equatable {
    public var clipURL: URL?
    public var name: String
    public var transport: ClipTransport
    public var effects: [Effect]

    public init(clipURL: URL? = nil, name: String = "",
                transport: ClipTransport = ClipTransport(), effects: [Effect] = []) {
        self.clipURL = clipURL
        self.name = name
        self.transport = transport
        self.effects = effects
    }

    public var isEmpty: Bool { clipURL == nil }

    public static func == (a: Cell, b: Cell) -> Bool {
        a.clipURL == b.clipURL && a.name == b.name
    }
}

/// What a grid cell is currently doing, for the UI to render.
public enum CellState: Sendable, Equatable {
    case empty
    case idle
    /// Triggered, waiting for the next quantised boundary.
    case armed(beatsRemaining: Double)
    case playing
}

/// A pending, quantised launch.
private struct PendingLaunch {
    var layer: Int
    var column: Int
    var fireAtBeat: Double
}

/// The clip grid and its launch behaviour.
public struct Deck: Sendable {
    /// `cells[layer][column]`.
    public private(set) var cells: [[Cell]]
    /// Column currently playing on each layer, or nil.
    public private(set) var active: [Int?]
    /// Global launch quantisation.
    public var quantise: Quantise = .bar

    private var pending: [PendingLaunch] = []

    public init(layers: Int, columns: Int) {
        let l = max(1, layers), c = max(1, columns)
        cells = Array(repeating: Array(repeating: Cell(), count: c), count: l)
        active = Array(repeating: nil, count: l)
    }

    public var layerCount: Int { cells.count }
    public var columnCount: Int { cells.first?.count ?? 0 }

    public subscript(layer: Int, column: Int) -> Cell {
        get { cells[layer][column] }
        set { cells[layer][column] = newValue }
    }

    // MARK: - Triggering

    /// Fires one cell, quantised.
    ///
    /// An empty cell is a no-op, **not** a clear: hitting an empty pad by
    /// accident mid-show must not black the layer.
    public mutating func trigger(layer: Int, column: Int, atBeat beat: Double) {
        guard cells.indices.contains(layer),
              cells[layer].indices.contains(column),
              !cells[layer][column].isEmpty else { return }

        if let q = quantise.beats {
            let fire = Self.nextBoundary(after: beat, every: q)
            // Re-triggering the same cell replaces the pending launch rather
            // than queueing a second one.
            pending.removeAll { $0.layer == layer }
            pending.append(PendingLaunch(layer: layer, column: column, fireAtBeat: fire))
        } else {
            pending.removeAll { $0.layer == layer }
            active[layer] = column
        }
    }

    /// Fires every non-empty cell in a column — the primary gesture.
    public mutating func triggerColumn(_ column: Int, atBeat beat: Double) {
        for layer in cells.indices {
            trigger(layer: layer, column: column, atBeat: beat)
        }
    }

    /// Clears a layer. Explicit, unlike triggering an empty cell.
    public mutating func clear(layer: Int) {
        guard active.indices.contains(layer) else { return }
        pending.removeAll { $0.layer == layer }
        active[layer] = nil
    }

    /// Advances to `beat`, firing anything whose boundary has passed.
    ///
    /// Returns the layers that changed, so the caller can reload only those
    /// rather than rebuilding the whole stack.
    @discardableResult
    public mutating func advance(toBeat beat: Double) -> [Int] {
        guard !pending.isEmpty else { return [] }
        var fired: [Int] = []
        pending.removeAll { p in
            // `>=` with a small epsilon: a launch exactly on the boundary must
            // fire this frame, not slip to the next one and land a frame late.
            guard beat >= p.fireAtBeat - 1e-9 else { return false }
            active[p.layer] = p.column
            fired.append(p.layer)
            return true
        }
        return fired
    }

    /// The next multiple of `every` strictly after `beat`.
    public static func nextBoundary(after beat: Double, every: Double) -> Double {
        guard every > 0 else { return beat }
        let n = (beat / every).rounded(.down) + 1
        return n * every
    }

    // MARK: - State for the UI

    public func state(layer: Int, column: Int, atBeat beat: Double) -> CellState {
        guard cells.indices.contains(layer), cells[layer].indices.contains(column) else {
            return .empty
        }
        if cells[layer][column].isEmpty { return .empty }
        if let p = pending.first(where: { $0.layer == layer && $0.column == column }) {
            return .armed(beatsRemaining: max(0, p.fireAtBeat - beat))
        }
        return active[layer] == column ? .playing : .idle
    }

    /// Layer states for the engine, derived from what is playing.
    public func layerStates(names: [String]? = nil) -> [LayerState] {
        cells.indices.map { layer in
            let col = active[layer]
            let cell = col.map { cells[layer][$0] }
            return LayerState(
                id: layer,
                name: names?[safe: layer] ?? cell?.name ?? "Layer \(layer + 1)",
                opacity: 1,
                blend: .over,
                clipURL: cell?.clipURL,
                effects: cell?.effects ?? [])
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
