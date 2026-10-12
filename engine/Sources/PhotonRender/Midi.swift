// MIDI — control surfaces in, pad state out.
//
// Two halves, and the second is the one people forget:
//
//  - **In**: notes, CCs and clock from a controller.
//  - **Out**: the pads on an APC40 or Launchpad **light up** to show which clips
//    are playing. That is why the control protocol is state-sync-first rather
//    than request/response — the engine pushes state outward continuously.
//
// The parser is deliberately separate from CoreMIDI so it can be tested against
// byte sequences instead of requiring hardware. That matters because the
// bug-prone part of MIDI is not the plumbing, it's **running status**.

import Foundation

/// A parsed MIDI message.
public enum MidiMessage: Equatable, Sendable {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case pitchBend(channel: UInt8, value: Int16)
    /// 24 per quarter note. Tempo source.
    case clock
    case start
    case `continue`
    case stop
    /// Song position in MIDI beats (16th notes). Coarse phase.
    case songPosition(beats: UInt16)

    /// The control class this maps to, for transport capability checks.
    public var isTempoRelated: Bool {
        switch self {
        case .clock, .start, .continue, .stop, .songPosition: return true
        default: return false
        }
    }
}

/// Incremental MIDI byte-stream parser.
///
/// Handles **running status**: a well-behaved controller omits the status byte
/// on repeated messages of the same type, so a parser that assumes every
/// message starts with a status byte drops most of a fader sweep. That is the
/// classic MIDI bug, and it presents as "the fader feels laggy" rather than as
/// an error.
public struct MidiParser {
    private var runningStatus: UInt8 = 0
    private var pending: [UInt8] = []

    public init() {}

    /// Feeds bytes, returning any complete messages.
    public mutating func parse(_ bytes: [UInt8]) -> [MidiMessage] {
        var out: [MidiMessage] = []
        for byte in bytes {
            if byte >= 0xF8 {
                // Realtime messages may appear ANYWHERE, including between the
                // data bytes of another message. They must not disturb it.
                if let m = Self.realtime(byte) { out.append(m) }
                continue
            }
            if byte >= 0x80 {
                // System common clears running status; channel messages set it.
                runningStatus = byte < 0xF0 ? byte : 0
                pending = byte < 0xF0 ? [] : [byte]
                if byte >= 0xF0 { pending = [byte] }
                continue
            }
            // Data byte.
            if !pending.isEmpty, pending[0] >= 0xF0 {
                pending.append(byte)
                if pending[0] == 0xF2, pending.count == 3 {
                    let lsb = UInt16(pending[1]), msb = UInt16(pending[2])
                    out.append(.songPosition(beats: (msb << 7) | lsb))
                    pending = []
                }
                continue
            }
            guard runningStatus != 0 else { continue }   // data before any status
            pending.append(byte)
            if pending.count == Self.dataLength(for: runningStatus) {
                if let m = Self.channelMessage(status: runningStatus, data: pending) {
                    out.append(m)
                }
                // Keep running status; the next message may omit it.
                pending = []
            }
        }
        return out
    }

    private static func dataLength(for status: UInt8) -> Int {
        // Program change and channel pressure take one data byte; the rest take two.
        switch status & 0xF0 {
        case 0xC0, 0xD0: return 1
        default: return 2
        }
    }

    private static func realtime(_ byte: UInt8) -> MidiMessage? {
        switch byte {
        case 0xF8: return .clock
        case 0xFA: return .start
        case 0xFB: return .continue
        case 0xFC: return .stop
        default: return nil
        }
    }

    private static func channelMessage(status: UInt8, data: [UInt8]) -> MidiMessage? {
        let ch = status & 0x0F
        switch status & 0xF0 {
        case 0x80:
            return .noteOff(channel: ch, note: data[0], velocity: data[1])
        case 0x90:
            // **Velocity 0 is a note-off.** Most controllers send this instead
            // of a real note-off; treating it as a note-on leaves pads latched
            // on and clips that never stop.
            return data[1] == 0
                ? .noteOff(channel: ch, note: data[0], velocity: 0)
                : .noteOn(channel: ch, note: data[0], velocity: data[1])
        case 0xB0:
            return .controlChange(channel: ch, controller: data[0], value: data[1])
        case 0xE0:
            let v = Int16(data[1]) << 7 | Int16(data[0])
            return .pitchBend(channel: ch, value: v - 8192)
        default:
            return nil
        }
    }
}

/// Derives tempo from MIDI clock.
///
/// 24 clocks per quarter note. Averaged over a window, because the jitter on a
/// single interval is large enough to make a derived BPM visibly unstable.
public struct MidiClockTracker {
    private var intervals: [Double] = []
    private var lastTick: Double?
    private let window = 48          // two quarter notes

    public init() {}

    /// Current tempo, or `nil` until enough ticks have arrived.
    public private(set) var bpm: Double?

    /// Feeds one clock tick at `time` (seconds, monotonic).
    public mutating func tick(at time: Double) {
        defer { lastTick = time }
        guard let last = lastTick else { return }
        let dt = time - last
        // Reject implausible intervals rather than letting one dropout drag the
        // average — 20..400 BPM is 0.0063..0.125 s per tick.
        guard dt > 0.004, dt < 0.2 else { return }

        intervals.append(dt)
        if intervals.count > window { intervals.removeFirst() }
        guard intervals.count >= 12 else { return }

        let mean = intervals.reduce(0, +) / Double(intervals.count)
        bpm = 60.0 / (mean * 24.0)
    }

    /// Clears state, e.g. on stop.
    public mutating func reset() {
        intervals.removeAll(keepingCapacity: true)
        lastTick = nil
        bpm = nil
    }
}

/// Outbound pad state, for lit control surfaces.
public struct MidiFeedback {
    /// Note-on with a colour/brightness velocity. Surfaces differ in their
    /// colour maps; the velocity is passed through rather than interpreted.
    public static func padOn(channel: UInt8, note: UInt8, colour: UInt8) -> [UInt8] {
        [0x90 | (channel & 0x0F), note & 0x7F, colour & 0x7F]
    }

    public static func padOff(channel: UInt8, note: UInt8) -> [UInt8] {
        [0x80 | (channel & 0x0F), note & 0x7F, 0]
    }
}
