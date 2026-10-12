// Transport-neutral control events.
//
// MIDI, OSC and the keyboard all arrive differently and all mean the same
// thing: *a control identified like this produced a reading like that.* This
// collapses them to one shape so there is a single place where a control enters
// the engine, rather than three.
//
// ## What is deliberately NOT here
//
// No mapping. Nothing in this file decides what a control *does* — that lives
// in `photon-core`, shared with the Windows shell. Putting even a little of it
// here would be the start of a second definition, and two definitions of a
// mapping drift into "the fader works on the Mac build".
//
// So this stays what it is: a decode of what the wire said.

import Foundation

/// How a control is identified.
public enum ControlKind: Sendable, Equatable {
    /// Continuous controller.
    case cc
    /// A pad or key on an instrument.
    case note
    /// The pitch wheel — the only 14-bit MIDI control.
    case pitchBend
    /// An OSC address.
    case osc
    /// A computer keyboard key.
    case key
}

/// A reading, at whatever resolution the transport carries.
public enum ControlReading: Sendable, Equatable {
    /// 7-bit MIDI, 0–127.
    case midi7(UInt8)
    /// 14-bit, 0–16383.
    case midi14(UInt16)
    /// Already normalised, 0–1.
    case unit(Float)
    /// A press or a release.
    case gate(Bool)
}

/// One control event, however it arrived.
public struct ControlEvent: Sendable, Equatable {
    public var kind: ControlKind
    /// MIDI channel, 0-based. Zero for OSC and keys.
    public var channel: UInt8
    /// Controller or note number. Zero where it does not apply.
    public var number: UInt8
    /// OSC address or key code.
    public var text: String
    public var reading: ControlReading

    public init(kind: ControlKind, channel: UInt8 = 0, number: UInt8 = 0,
                text: String = "", reading: ControlReading) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.text = text
        self.reading = reading
    }
}

public extension MidiMessage {
    /// This message as a control event, or nil if it carries no control.
    ///
    /// Clock and transport are excluded: they drive the clock, not the mapper.
    /// Binding a fader to MIDI clock would be meaningless and would flood learn
    /// mode at 24 messages a beat — which is exactly what happens if you let
    /// every message through.
    var controlEvent: ControlEvent? {
        switch self {
        case .controlChange(let channel, let controller, let value):
            return ControlEvent(kind: .cc, channel: channel, number: controller,
                                reading: .midi7(value))

        case .noteOn(let channel, let note, let velocity):
            // Velocity 0 is a release. In the spec, emitted constantly by real
            // hardware under running status, and a mapper that misses it leaves
            // pads latched on.
            return ControlEvent(kind: .note, channel: channel, number: note,
                                reading: .gate(velocity > 0))

        case .noteOff(let channel, let note, _):
            return ControlEvent(kind: .note, channel: channel, number: note,
                                reading: .gate(false))

        case .pitchBend(let channel, let value):
            // The wire is 0–16383 with 8192 at the detent; the parser hands it
            // over signed and centred. Shift it back rather than inventing a
            // second convention.
            let raw = Int(value) + 8192
            return ControlEvent(kind: .pitchBend, channel: channel,
                                reading: .midi14(UInt16(max(0, min(16383, raw)))))

        case .clock, .start, .continue, .stop, .songPosition:
            return nil
        }
    }
}

public extension OSCMessage {
    /// This message as a control event, or nil if it carries no usable value.
    ///
    /// The address identifies the control and the first numeric argument is the
    /// reading — the convention every OSC surface already follows. An argument
    /// list with nothing numeric in it (a bare `/go`) reads as a **press**,
    /// because that is what sending it means.
    var controlEvent: ControlEvent? {
        guard address.hasPrefix("/") else { return nil }
        if let v = firstFloat {
            return ControlEvent(kind: .osc, text: address, reading: .unit(v))
        }
        if values.isEmpty {
            return ControlEvent(kind: .osc, text: address, reading: .gate(true))
        }
        return nil
    }
}

/// A keyboard key as a control event.
public func keyControlEvent(code: String, pressed: Bool) -> ControlEvent {
    ControlEvent(kind: .key, text: code, reading: .gate(pressed))
}
