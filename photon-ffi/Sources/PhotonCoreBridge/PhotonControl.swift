// Swift face of the core's control mapping and learn mode.
//
// Thin on purpose. The mapping *model* — what a source is, how pickup behaves,
// what a learn displaces — lives in `photon-core` and is shared with the
// Windows shell. This file translates, and does nothing else.
//
// The one thing it must not become is a second definition of that model. So
// outcomes arrive as a packed `PhotonRouted` and are read here into a Swift
// enum for the call site; nothing is re-decided, re-ranged or re-shaped.

import Foundation
import PhotonFFI

/// A physical control, as the shell decoded it off the wire.
public enum ControlSource: Hashable, Sendable {
    case midiCC(channel: UInt8, cc: UInt8)
    case midiNote(channel: UInt8, note: UInt8)
    case midiPitchBend(channel: UInt8)
    case osc(address: String)
    case key(code: String)

    /// Text payload, if this source carries one.
    var text: String? {
        switch self {
        case .osc(let a): return a
        case .key(let c): return c
        default: return nil
        }
    }

    private var raw: (Int32, UInt8, UInt8) {
        switch self {
        case .midiCC(let ch, let cc): return (Int32(PHOTON_SOURCE_MIDI_CC), ch, cc)
        case .midiNote(let ch, let n): return (Int32(PHOTON_SOURCE_MIDI_NOTE), ch, n)
        case .midiPitchBend(let ch): return (Int32(PHOTON_SOURCE_MIDI_PITCH_BEND), ch, 0)
        case .osc: return (Int32(PHOTON_SOURCE_OSC), 0, 0)
        case .key: return (Int32(PHOTON_SOURCE_KEY), 0, 0)
        }
    }

    /// Builds the C struct and calls `body` with it.
    ///
    /// Scoped rather than returned because the struct borrows a C string whose
    /// lifetime must not outlive the call — returning it would hand back a
    /// dangling pointer that works until it doesn't.
    func withCStruct<T>(_ body: (PhotonControlSource) -> T) -> T {
        let (kind, channel, number) = raw
        guard let text else {
            return body(PhotonControlSource(kind: kind, channel: channel,
                                            number: number, text: nil))
        }
        return text.withCString { pointer in
            body(PhotonControlSource(kind: kind, channel: channel,
                                     number: number, text: pointer))
        }
    }
}

/// Something a control can do that is not a parameter.
public enum ControlAction: Hashable, Sendable {
    case triggerCell(layer: UInt32, column: UInt32)
    case triggerColumn(column: UInt32)
    case clearLayer(layer: UInt32)
    case cueGo
    case blackout
    case tapTempo
    case resync

    var raw: (Int32, UInt32, UInt32) {
        switch self {
        case .triggerCell(let l, let c): return (Int32(PHOTON_ACTION_TRIGGER_CELL), l, c)
        case .triggerColumn(let c): return (Int32(PHOTON_ACTION_TRIGGER_COLUMN), c, 0)
        case .clearLayer(let l): return (Int32(PHOTON_ACTION_CLEAR_LAYER), l, 0)
        case .cueGo: return (Int32(PHOTON_ACTION_CUE_GO), 0, 0)
        case .blackout: return (Int32(PHOTON_ACTION_BLACKOUT), 0, 0)
        case .tapTempo: return (Int32(PHOTON_ACTION_TAP_TEMPO), 0, 0)
        case .resync: return (Int32(PHOTON_ACTION_RESYNC), 0, 0)
        }
    }

    static func from(_ action: Int32, _ a: UInt32, _ b: UInt32) -> ControlAction? {
        switch action {
        case Int32(PHOTON_ACTION_TRIGGER_CELL): return .triggerCell(layer: a, column: b)
        case Int32(PHOTON_ACTION_TRIGGER_COLUMN): return .triggerColumn(column: a)
        case Int32(PHOTON_ACTION_CLEAR_LAYER): return .clearLayer(layer: a)
        case Int32(PHOTON_ACTION_CUE_GO): return .cueGo
        case Int32(PHOTON_ACTION_BLACKOUT): return .blackout
        case Int32(PHOTON_ACTION_TAP_TEMPO): return .tapTempo
        case Int32(PHOTON_ACTION_RESYNC): return .resync
        default: return nil
        }
    }
}

/// An inbound reading, in whatever resolution the transport carries.
public enum ControlValue: Sendable {
    /// 7-bit MIDI, 0–127.
    case midi7(UInt8)
    /// 14-bit pitch bend, 0–16383.
    case midi14(UInt16)
    /// Already normalised, 0–1.
    case unit(Double)
    /// A press or a release.
    case gate(Bool)

    /// A note-on, applying the spec's velocity-0 rule: a note-on with velocity
    /// 0 **is** a note-off. Real hardware does this constantly, and a mapper
    /// that misses it leaves pads latched on.
    public static func noteOn(velocity: UInt8) -> ControlValue { .gate(velocity > 0) }

    var raw: (Int32, Float) {
        switch self {
        case .midi7(let v): return (Int32(PHOTON_VALUE_MIDI7), Float(v))
        case .midi14(let v): return (Int32(PHOTON_VALUE_MIDI14), Float(v))
        case .unit(let v): return (Int32(PHOTON_VALUE_UNIT), Float(v))
        case .gate(let on): return (Int32(PHOTON_VALUE_GATE), on ? 1 : 0)
        }
    }
}

/// Why an event produced nothing.
///
/// Routing silently is indistinguishable from a broken cable, so every dead end
/// carries a reason a monitor view can show.
public enum ControlIgnored: Sendable {
    case unbound
    case release
    case awaitingPickup

    /// Operator-facing wording.
    public var reason: String {
        switch self {
        case .unbound: return "nothing bound"
        case .release: return "release ignored"
        case .awaitingPickup: return "move through the current value to take control"
        }
    }
}

/// What happened to one control event.
public enum ControlOutcome: Sendable {
    /// Move a parameter to `position` within its own sweep.
    case parameter(path: String, position: Double)
    /// Fire an action.
    case action(ControlAction)
    /// Learn is armed and waiting for the control to move.
    case learning
    /// Learn captured the control. `displaced` names what it took the control
    /// away from, and should be **shown** — a pad silently stolen from blackout
    /// is how a show loses its panic button.
    case learned(displaced: String?)
    /// Nothing happened, and why.
    case ignored(ControlIgnored)
}

/// Control mapping on a live core handle.
///
/// Free functions over the handle rather than a wrapper object: the handle's
/// lifetime belongs to whoever created it, and a second owner is how a
/// double-free happens.
public enum PhotonControl {
    /// Arms learn for a parameter. The next control that **moves** binds to it.
    @discardableResult
    public static func arm(handle: OpaquePointer?, parameter path: String) -> Bool {
        guard let handle else { return false }
        return path.withCString { photon_control_arm_parameter(handle, $0) }
    }

    /// Arms learn for an action.
    @discardableResult
    public static func arm(handle: OpaquePointer?, action: ControlAction) -> Bool {
        guard let handle else { return false }
        let (kind, a, b) = action.raw
        return photon_control_arm_action(handle, kind, a, b)
    }

    /// Cancels learn without binding anything.
    public static func disarm(handle: OpaquePointer?) {
        photon_control_disarm(handle)
    }

    /// Whether learn is waiting, for the armed indicator.
    public static func isLearning(handle: OpaquePointer?) -> Bool {
        photon_control_is_learning(handle)
    }

    /// Feeds one decoded event.
    ///
    /// `currentPosition` is the target parameter's present 0–1 position, which
    /// is what pickup compares against. Pass `nil` when it is unknown — a value
    /// nothing knows cannot jump, so pickup steps aside rather than blocking
    /// the control for its own sake.
    public static func event(
        handle: OpaquePointer?,
        source: ControlSource,
        value: ControlValue,
        currentPosition: Double? = nil
    ) -> ControlOutcome {
        guard let handle else { return .ignored(.unbound) }
        let (valueKind, raw) = value.raw
        let current = Float(currentPosition ?? -1)
        let routed = source.withCStruct { c in
            photon_control_event(handle, c, valueKind, raw, current)
        }
        return decode(routed)
    }

    private static func decode(_ r: PhotonRouted) -> ControlOutcome {
        switch r.kind {
        case Int32(PHOTON_ROUTED_PARAMETER):
            // Read the string NOW: it is valid only until the next control
            // call on this handle.
            let path = r.path.map { String(cString: $0) } ?? ""
            return .parameter(path: path, position: Double(r.position))
        case Int32(PHOTON_ROUTED_ACTION):
            guard let action = ControlAction.from(r.action, r.a, r.b) else {
                return .ignored(.unbound)
            }
            return .action(action)
        case Int32(PHOTON_ROUTED_LEARNING):
            return .learning
        case Int32(PHOTON_ROUTED_LEARNED):
            let label = r.displaced != 0 ? r.displaced_label.map { String(cString: $0) } : nil
            return .learned(displaced: label)
        default:
            switch r.ignored {
            case Int32(PHOTON_IGNORED_RELEASE): return .ignored(.release)
            case Int32(PHOTON_IGNORED_AWAITING_PICKUP): return .ignored(.awaitingPickup)
            default: return .ignored(.unbound)
            }
        }
    }

    /// Removes one binding. True if something was bound.
    @discardableResult
    public static func unbind(handle: OpaquePointer?, source: ControlSource) -> Bool {
        guard let handle else { return false }
        return source.withCStruct { photon_control_unbind(handle, $0) }
    }

    /// Makes every control re-earn pickup — after a bank switch or page change.
    public static func resetPickup(handle: OpaquePointer?) {
        photon_control_reset_pickup(handle)
    }

    /// The parameter path a source is bound to, or nil.
    public static func boundPath(handle: OpaquePointer?, source: ControlSource) -> String? {
        guard let handle else { return nil }
        return source.withCStruct { photon_control_bound_path(handle, $0).map { String(cString: $0) } }
    }

    /// Number of bindings, for a status line.
    public static func bindingCount(handle: OpaquePointer?) -> Int {
        Int(photon_control_binding_count(handle))
    }

    /// The map as JSON, for saving alongside the document.
    public static func map(handle: OpaquePointer?) -> String? {
        guard let handle else { return nil }
        let s = photon_control_map(handle)
        defer { photon_string_free(s) }
        guard s.ok != 0, let ptr = s.ptr else { return nil }
        return String(cString: ptr)
    }

    /// Replaces the map. Returns the failure reason, or nil on success.
    ///
    /// The reason is returned rather than swallowed because "the map didn't
    /// load" with no explanation is useless to someone standing in a venue.
    public static func loadMap(handle: OpaquePointer?, json: String) -> String? {
        guard let handle else { return "no engine" }
        let result = json.withCString { photon_control_map_load(handle, $0) }
        defer { photon_string_free(result) }
        if result.ok != 0 { return nil }
        return result.ptr.map { String(cString: $0) } ?? "unknown failure"
    }
}
