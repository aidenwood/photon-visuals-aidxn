// Cue list and autopilot.
//
// Two different jobs that share one structure, and conflating them is a classic
// mistake:
//
//  - **Cue list** — a human presses GO and the show advances one step. Used in
//    theatre and corporate, where timing is cued to something happening in the
//    room.
//  - **Autopilot** — the show advances itself after a set musical duration.
//    Used when nobody is driving, or to free the operator's hands.
//
// Both walk the same list; the difference is only what triggers the step. That
// matters because an operator switching between them mid-show must not lose
// their position.
//
// Advancing is **quantised through the deck**, like any other trigger, so an
// auto-advance lands on the beat exactly as a manual press would.

import Foundation

/// One step in a cue list.
public struct Cue: Sendable, Equatable {
    public var name: String
    /// Grid column this cue fires.
    public var column: Int
    /// Musical beats to hold before auto-advancing. `nil` = wait for GO, even
    /// in autopilot — which is how you build a show that runs itself up to a
    /// point and then waits for a human.
    public var holdBeats: Double?

    public init(name: String, column: Int, holdBeats: Double? = nil) {
        self.name = name
        self.column = column
        self.holdBeats = holdBeats
    }
}

/// How the cue list advances.
public enum CueMode: Sendable, Equatable {
    /// Advance only on an explicit GO.
    case manual
    /// Advance automatically after each cue's hold, where one is set.
    case autopilot
}

/// A cue list with optional autopilot.
public struct CueList: Sendable {
    public private(set) var cues: [Cue]
    public var mode: CueMode = .manual
    /// Wrap to the start after the last cue. Off by default: a show that
    /// silently loops back to the top is rarely what anyone wanted.
    public var loops = false

    /// Index of the cue currently standing, or nil before the first GO.
    public private(set) var current: Int?
    /// Beat at which the current cue fired, for hold timing.
    private var firedAtBeat: Double = 0

    public init(cues: [Cue] = []) {
        self.cues = cues
    }

    public mutating func append(_ cue: Cue) { cues.append(cue) }
    public mutating func removeAll() { cues.removeAll(); current = nil }

    /// The cue that will fire next on GO.
    public var next: Cue? {
        guard !cues.isEmpty else { return nil }
        guard let c = current else { return cues.first }
        let n = c + 1
        if n < cues.count { return cues[n] }
        return loops ? cues.first : nil
    }

    /// Beats remaining before autopilot advances, if it will.
    public func beatsUntilAdvance(atBeat beat: Double) -> Double? {
        guard mode == .autopilot,
              let c = current, c < cues.count,
              let hold = cues[c].holdBeats else { return nil }
        return max(0, (firedAtBeat + hold) - beat)
    }

    /// Fires the next cue. Returns the column to trigger, or nil at the end.
    ///
    /// This is GO. It behaves identically in both modes — an operator can
    /// always take manual control without the list losing its place.
    public mutating func go(atBeat beat: Double) -> Int? {
        guard !cues.isEmpty else { return nil }
        let target: Int
        if let c = current {
            let n = c + 1
            if n < cues.count { target = n }
            else if loops { target = 0 }
            else { return nil }
        } else {
            target = 0
        }
        current = target
        firedAtBeat = beat
        return cues[target].column
    }

    /// Jumps directly to a cue, e.g. an operator clicking down the list.
    public mutating func goTo(_ index: Int, atBeat beat: Double) -> Int? {
        guard cues.indices.contains(index) else { return nil }
        current = index
        firedAtBeat = beat
        return cues[index].column
    }

    /// Advances if autopilot is due. Returns a column to fire, or nil.
    ///
    /// Called every frame; cheap when idle.
    public mutating func tick(atBeat beat: Double) -> Int? {
        guard mode == .autopilot, let c = current, c < cues.count,
              let hold = cues[c].holdBeats,
              beat >= firedAtBeat + hold else { return nil }
        return go(atBeat: beat)
    }

    /// Returns to the top without firing anything — the standby state before a
    /// show starts.
    public mutating func reset() {
        current = nil
        firedAtBeat = 0
    }
}
