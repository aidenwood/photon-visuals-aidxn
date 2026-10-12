// Clip transport — how a clip's playback position is driven.
//
// Mirrors Resolume's model, because an operator moving between tools should not
// have to relearn it:
//
//   Timeline  — free-running at the clip's own rate. Not tempo-locked.
//   BPM Sync  — loop length quantised to musical time; the playback RATE is
//               derived from tempo so the clip always lands on the beat.
//   Position  — driven directly by a parameter, so it can be modulated.
//
// Orthogonal to that is what happens at the end: loop, once, ping-pong, random,
// hold-last-frame.
//
// The rate maths lives in `photon-core` (`Clock::bpm_sync_rate`) so the Windows
// shell gets identical behaviour. This file is the Swift-side mirror of the
// *model*, not a second implementation of the maths.

import AVFoundation
import Foundation

/// How a clip's position is driven.
public enum TransportMode: Sendable, Equatable {
    /// Free-running at the clip's native rate.
    case timeline
    /// Locked to tempo: the clip's loop spans `beats` musical beats.
    case bpmSync(beats: Int)
    /// Position set externally, so it can be modulated.
    case position
}

/// What happens when playback reaches the out point.
public enum Playthrough: String, Sendable, CaseIterable {
    case loop, once, pingPong, random, holdLast

    public var name: String {
        switch self {
        case .loop: return "Loop"
        case .once: return "Once"
        case .pingPong: return "Ping-Pong"
        case .random: return "Random"
        case .holdLast: return "Hold Last"
        }
    }
}

/// Playback state for one clip.
public struct ClipTransport: Sendable {
    /// How position is driven.
    public var mode: TransportMode
    /// End-of-clip behaviour.
    public var playthrough: Playthrough
    /// Trim in point, normalised 0..1.
    public var trimIn: Double
    /// Trim out point, normalised 0..1.
    public var trimOut: Double
    /// Current direction. Only ping-pong ever reverses.
    public var reversed: Bool

    public init(mode: TransportMode = .timeline,
                playthrough: Playthrough = .loop,
                trimIn: Double = 0, trimOut: Double = 1,
                reversed: Bool = false) {
        self.mode = mode
        self.playthrough = playthrough
        // A zero- or negative-width trim would stall playback with no
        // indication why, so it is rejected at construction rather than
        // producing a clip that silently never advances.
        self.trimIn = max(0, min(trimIn, 0.999))
        self.trimOut = max(self.trimIn + 0.001, min(trimOut, 1))
        self.reversed = reversed
    }

    /// Length of the trimmed region, as a fraction of the clip.
    public var span: Double { trimOut - trimIn }

    /// Playback rate multiplier for the current mode.
    ///
    /// For BPM sync: a clip of `clipSeconds` whose loop should span `beats` at
    /// `bpm` must play at `(clip length) / (musical length)`. Deriving the RATE
    /// rather than resampling means the clip always lands on the beat no matter
    /// how its native length relates to the tempo.
    public func rate(bpm: Double, clipSeconds: Double) -> Double {
        switch mode {
        case .timeline, .position:
            return 1.0
        case .bpmSync(let beats):
            guard bpm > 0, clipSeconds > 0, beats > 0 else { return 1.0 }
            let musicalSeconds = Double(beats) * 60.0 / bpm
            guard musicalSeconds > 0 else { return 1.0 }
            return (clipSeconds * span) / musicalSeconds
        }
    }

    /// Advances a normalised position, applying playthrough behaviour.
    ///
    /// Returns the new position and whether the clip has finished (only
    /// meaningful for `.once`).
    public func advance(position: Double, by delta: Double,
                        randomSource: () -> Double = { Double.random(in: 0...1) })
        -> (position: Double, finished: Bool) {

        guard span > 0 else { return (trimIn, true) }
        var p = position
        var dir = reversed ? -1.0 : 1.0

        p += delta * dir

        switch playthrough {
        case .loop:
            if p >= trimOut { p = trimIn + (p - trimOut).truncatingRemainder(dividingBy: span) }
            if p < trimIn { p = trimOut - (trimIn - p).truncatingRemainder(dividingBy: span) }
            return (p, false)

        case .once:
            if p >= trimOut { return (trimOut, true) }
            if p < trimIn { return (trimIn, true) }
            return (p, false)

        case .holdLast:
            // Distinct from `.once` only in intent: the frame stays on screen.
            // Blackout must remain an explicit operator action, never a side
            // effect of a clip ending.
            return (min(max(p, trimIn), trimOut), p >= trimOut)

        case .pingPong:
            if p >= trimOut {
                dir = -1
                p = trimOut - (p - trimOut)
            } else if p < trimIn {
                dir = 1
                p = trimIn + (trimIn - p)
            }
            return (min(max(p, trimIn), trimOut), false)

        case .random:
            if p >= trimOut || p < trimIn {
                return (trimIn + randomSource() * span, false)
            }
            return (p, false)
        }
    }
}

public extension ClipTransport {
    /// Whether the direction should flip after this advance (ping-pong only).
    func flips(position: Double, by delta: Double) -> Bool {
        guard playthrough == .pingPong else { return false }
        let p = position + delta * (reversed ? -1 : 1)
        return p >= trimOut || p < trimIn
    }
}
