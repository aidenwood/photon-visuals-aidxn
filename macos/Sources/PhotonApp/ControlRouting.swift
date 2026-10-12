// Joins the engine's decoded control events to the core's mapper.
//
// The engine decodes the wire (`PhotonRender.ControlEvent`); the core decides
// what a control does (`PhotonCoreBridge`). This is the seam between them, and
// it is deliberately nothing but a translation — any logic that crept in here
// would be logic the Windows shell does not have.

import PhotonCoreBridge
import PhotonRender

extension ControlEvent {
    /// How the core identifies this control.
    var coreSource: ControlSource {
        switch kind {
        case .cc: return .midiCC(channel: channel, cc: number)
        case .note: return .midiNote(channel: channel, note: number)
        case .pitchBend: return .midiPitchBend(channel: channel)
        case .osc: return .osc(address: text)
        case .key: return .key(code: text)
        }
    }

    /// The reading, at the core's resolutions.
    var coreValue: PhotonCoreBridge.ControlValue {
        switch reading {
        case .midi7(let v): return .midi7(v)
        case .midi14(let v): return .midi14(v)
        case .unit(let v): return .unit(Double(v))
        case .gate(let on): return .gate(on)
        }
    }
}

extension PhotonCoreSession {
    /// Queues an event from CoreMIDI, the OSC socket or the keyboard.
    ///
    /// Queued rather than routed, because those arrive on their own threads and
    /// the handle belongs to the render thread.
    func enqueue(_ event: ControlEvent) {
        enqueue(source: event.coreSource, value: event.coreValue)
    }

    /// Queues every control-carrying message in a MIDI batch.
    func enqueue(midi messages: [MidiMessage]) {
        for event in messages.compactMap(\.controlEvent) { enqueue(event) }
    }

    /// Queues every control-carrying message from the OSC listener.
    func enqueue(osc messages: [OSCMessage]) {
        for event in messages.compactMap(\.controlEvent) { enqueue(event) }
    }
}
