// A live core handle, owned.
//
// Everything the Rust core computes — musical time, modulation, control
// mapping — reaches the app through here. Before this existed the app
// validated the ABI and then never called it, so the clock and the mapper were
// written, tested, and doing nothing.
//
// ## Ownership
//
// One object owns the handle and frees it in `deinit`. That is the whole
// reason this is a class rather than a struct: two owners of a C pointer is a
// double free, and a struct copied into a closure is two owners.
//
// ## Threading
//
// **Not thread-safe, by design.** The handle is driven from the render thread,
// which is the only thread that knows what frame it is. Control events arrive
// on CoreMIDI's and the network's threads and must be *handed* to the render
// thread rather than calling in directly — see `pendingControl`.
//
// A lock here would be worse than the rule: it would hide a priority inversion
// inside the frame loop, which is the one place in this program that cannot
// afford to wait on anything.

import Foundation
import PhotonFFI

/// One layer, as handed to the core.
public struct CoreLayer: Sendable, Equatable {
    public var id: UInt32
    /// Blend mode discriminant, matching the core's `BlendMode`.
    public var blend: Int32
    public var opacity: Float
    /// Index into the shell's bound texture array, or -1.
    public var textureSlot: Int32
    /// Normalised playback position, 0–1.
    public var position: Float
    public var active: Bool

    public init(id: UInt32, blend: Int32 = 0, opacity: Float = 1,
                textureSlot: Int32 = -1, position: Float = 0, active: Bool = true) {
        self.id = id
        self.blend = blend
        self.opacity = opacity
        self.textureSlot = textureSlot
        self.position = position
        self.active = active
    }
}

/// Musical state for one frame.
public struct CoreFrame: Sendable, Equatable {
    /// Continuous beat position.
    public var beat: Double
    /// Beat phase, 0–1 — what a beat-synced visual actually reads.
    public var phase: Float
    public var bpm: Float
    /// Frames produced since creation, for drift checks.
    public var frameIndex: UInt64
    public var layerCount: Int
}

/// Owns a core handle for the lifetime of a composition.
public final class PhotonCoreSession {
    private let handle: OpaquePointer
    /// Scratch for the packed layer array, reused so a frame allocates nothing.
    private var packed: [PhotonLayer] = []

    /// Creates a session, or nil if the core refuses.
    public init?(bpm: Float = 120) {
        guard let h = photon_create(bpm) else { return nil }
        handle = h
    }

    deinit { photon_destroy(handle) }

    // MARK: - Frame

    /// Replaces the layer stack. Called on edits, **not** per frame.
    public func setLayers(_ layers: [CoreLayer]) {
        packed = layers.map {
            PhotonLayer(id: $0.id, blend: $0.blend, opacity: $0.opacity,
                        tex_slot: $0.textureSlot, position: $0.position,
                        active: $0.active ? 1 : 0)
        }
        if packed.isEmpty {
            photon_set_layers(handle, nil, 0)
        } else {
            photon_set_layers(handle, &packed, UInt32(packed.count))
        }
    }

    /// Advances the core by `deltaNanos` and returns this frame's musical state.
    ///
    /// One crossing per frame. At 12 layers and 120fps, per-layer calls would be
    /// 1,440 crossings a second; this is 120.
    @discardableResult
    public func tick(deltaNanos: UInt64) -> CoreFrame {
        let f = photon_tick(handle, deltaNanos)
        return CoreFrame(beat: f.beat, phase: f.phase, bpm: f.bpm,
                         frameIndex: f.frame_index, layerCount: Int(f.layer_count))
    }

    /// Ticks and gives `body` the packed layer array **in place**.
    ///
    /// The buffer belongs to the core and is valid only for the duration of the
    /// call — it is replaced by the next tick. Copying it out would undo the
    /// point of packing it in the first place.
    public func tick<T>(deltaNanos: UInt64,
                        layers body: (UnsafeBufferPointer<PhotonLayer>, CoreFrame) -> T) -> T {
        let f = photon_tick(handle, deltaNanos)
        let frame = CoreFrame(beat: f.beat, phase: f.phase, bpm: f.bpm,
                              frameIndex: f.frame_index, layerCount: Int(f.layer_count))
        let buffer = UnsafeBufferPointer(start: f.layers, count: Int(f.layer_count))
        return body(buffer, frame)
    }

    /// Sets the tempo.
    public func setBPM(_ bpm: Float) {
        photon_set_bpm(handle, bpm)
    }

    /// Enables or disables the beat-synced opacity LFO.
    public func setBeatLFO(enabled: Bool, beats: Float) {
        photon_set_beat_lfo(handle, enabled, beats)
    }

    // MARK: - Audio reactivity

    /// Binds an audio band to a parameter.
    ///
    /// `depth` is in normalised sweep space: 1 means the band drives the
    /// parameter's full start/stop range. The binding is **declared**, so it
    /// survives stack edits — and is restored if a layer it referred to comes
    /// back, rather than making the operator make it again.
    @discardableResult
    public func bindAudio(parameter path: String, lowHz: Float, highHz: Float,
                          attackMs: Float = 5, releaseMs: Float = 120,
                          depth: Float = 1, invert: Bool = false) -> Bool {
        path.withCString {
            photon_bind_audio(handle, $0, lowHz, highHz, attackMs, releaseMs, depth, invert)
        }
    }

    /// Removes every audio binding on a parameter.
    @discardableResult
    public func unbindAudio(parameter path: String) -> Bool {
        path.withCString { photon_unbind_audio(handle, $0) }
    }

    /// The frequency ranges the analyser should compute — and only those.
    ///
    /// Driven by what is bound, so a composition with nothing audio-reactive
    /// runs no filter bank at all.
    public var audioBands: [(low: Float, high: Float)] {
        let count = Int(photon_audio_band_count(handle))
        var out: [(low: Float, high: Float)] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            var lo: Float = 0, hi: Float = 0
            if photon_audio_band(handle, UInt32(i), &lo, &hi) { out.append((lo, hi)) }
        }
        return out
    }

    /// Pushes this frame's **raw** band energies, in `audioBands` order.
    ///
    /// Raw, not enveloped — see `AudioSnapshot.rawLevels`.
    public func setAudioBands(_ values: [Float]) {
        for (i, v) in values.enumerated() {
            _ = photon_set_audio_band(handle, UInt32(i), v)
        }
    }

    // MARK: - Control

    /// Arms learn for a parameter. The next control that **moves** binds to it.
    @discardableResult
    public func arm(parameter path: String) -> Bool {
        PhotonControl.arm(handle: handle, parameter: path)
    }

    /// Arms learn for an action.
    @discardableResult
    public func arm(action: ControlAction) -> Bool {
        PhotonControl.arm(handle: handle, action: action)
    }

    /// Cancels learn without binding anything.
    public func disarm() { PhotonControl.disarm(handle: handle) }

    /// Whether learn is waiting for a control.
    public var isLearning: Bool { PhotonControl.isLearning(handle: handle) }

    /// Number of bindings, for a status line.
    public var bindingCount: Int { PhotonControl.bindingCount(handle: handle) }

    /// Routes one control event.
    ///
    /// `currentPosition` is what pickup compares against; `nil` means unknown,
    /// and pickup steps aside rather than blocking a control for its own sake.
    public func route(source: ControlSource, value: ControlValue,
                      currentPosition: Double? = nil) -> ControlOutcome {
        PhotonControl.event(handle: handle, source: source, value: value,
                            currentPosition: currentPosition)
    }

    /// Removes one binding.
    @discardableResult
    public func unbind(_ source: ControlSource) -> Bool {
        PhotonControl.unbind(handle: handle, source: source)
    }

    /// Makes every control re-earn pickup — after a bank or page change.
    public func resetPickup() { PhotonControl.resetPickup(handle: handle) }

    /// The control map as JSON, for saving alongside the document.
    public var controlMapJSON: String? { PhotonControl.map(handle: handle) }

    /// Replaces the control map. Returns the failure reason, or nil on success.
    @discardableResult
    public func loadControlMap(json: String) -> String? {
        PhotonControl.loadMap(handle: handle, json: json)
    }

    // MARK: - Handing control events to the render thread

    private let inboxLock = NSLock()
    private var inbox: [(ControlSource, ControlValue)] = []

    /// Queues an event from a non-render thread — CoreMIDI, the OSC socket, the
    /// remote.
    ///
    /// Bounded: a desk that floods, or a remote that reconnects in a loop, must
    /// cost control responsiveness rather than memory. The oldest go first,
    /// because in a flood the newest reading is the true one — an operator's
    /// hand is where it is now, not where it was 500 messages ago.
    public func enqueue(source: ControlSource, value: ControlValue) {
        inboxLock.lock()
        inbox.append((source, value))
        if inbox.count > Self.maxPending {
            inbox.removeFirst(inbox.count - Self.maxPending)
        }
        inboxLock.unlock()
    }

    /// Queue bound. 512 is roughly four seconds of a very chatty desk.
    public static let maxPending = 512

    /// Drains queued events through the router. **Render thread only.**
    ///
    /// `currentPosition` is asked for per target so pickup has something real
    /// to compare against.
    public func drainControl(
        currentPosition: (String) -> Double? = { _ in nil }
    ) -> [ControlOutcome] {
        inboxLock.lock()
        let pending = inbox
        inbox.removeAll(keepingCapacity: true)
        inboxLock.unlock()

        guard !pending.isEmpty else { return [] }
        var out: [ControlOutcome] = []
        out.reserveCapacity(pending.count)
        for (source, value) in pending {
            // The router needs the target's present value, but only it knows
            // what the target is — so ask once without it, and only pay for a
            // lookup when a binding actually exists.
            out.append(route(source: source, value: value,
                             currentPosition: currentPositionFor(source, currentPosition)))
        }
        return out
    }

    private func currentPositionFor(_ source: ControlSource,
                                    _ lookup: (String) -> Double?) -> Double? {
        guard let path = boundPath(for: source) else { return nil }
        return lookup(path)
    }

    /// The parameter path a source is bound to, if any.
    ///
    /// Asks the core directly rather than reading the saved map: serialising
    /// and parsing the whole map per event would cost a full JSON round-trip on
    /// **every message of a fader sweep**.
    public func boundPath(for source: ControlSource) -> String? {
        source.withCStruct { c in
            photon_control_bound_path(handle, c).map { String(cString: $0) }
        }
    }
}