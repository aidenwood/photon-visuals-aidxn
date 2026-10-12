// Control mapping across the real C boundary.
//
// The Rust side is tested in `photon-ffi`; this proves the *Swift translation*
// — enum discriminants, struct layout, and the string lifetime rule — against
// the actual linked library rather than against a mirror of it.
//
// Discriminant drift is the failure this catches. A mismatched value does not
// crash: a fader binds, and then moves the wrong parameter, which is found out
// on site.

import PhotonCoreBridge
import PhotonFFI

enum ControlProbeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self { case .failed(let what): return what }
    }
}

private func expect(_ condition: Bool, _ what: String) throws {
    if !condition { throw ControlProbeError.failed(what) }
}

func checkControlRoundTrip() throws {
    guard let handle = photon_create(120) else {
        throw ControlProbeError.failed("could not create a core handle")
    }
    defer { photon_destroy(handle) }

    // Struct strides, for the same reason the frame check exists: same-size
    // field reordering is invisible until a value is subtly wrong.
    try expect(Int(photon_routed_stride()) == MemoryLayout<PhotonRouted>.stride,
               "PhotonRouted stride mismatch")
    try expect(Int(photon_control_source_stride()) == MemoryLayout<PhotonControlSource>.stride,
               "PhotonControlSource stride mismatch")

    // Learn: a fader must move before it binds.
    try expect(PhotonControl.arm(handle: handle, parameter: "layer.1.opacity"),
               "arming a parameter failed")
    try expect(PhotonControl.isLearning(handle: handle), "learn did not arm")

    let fader = ControlSource.midiCC(channel: 0, cc: 7)
    guard case .learning = PhotonControl.event(handle: handle, source: fader, value: .midi7(0))
    else { throw ControlProbeError.failed("the first reading should be a reference, not a bind") }

    guard case .learned(let displaced) = PhotonControl.event(
        handle: handle, source: fader, value: .midi7(100))
    else { throw ControlProbeError.failed("a moving fader should have bound") }
    try expect(displaced == nil, "nothing was bound, so nothing can be displaced")
    try expect(!PhotonControl.isLearning(handle: handle), "learn should have disarmed")
    try expect(PhotonControl.bindingCount(handle: handle) == 1, "expected one binding")

    // Routing, and the string crossing intact.
    guard case .parameter(let path, let position) = PhotonControl.event(
        handle: handle, source: fader, value: .midi7(127))
    else { throw ControlProbeError.failed("a bound fader should move its parameter") }
    try expect(path == "layer.1.opacity", "path came back as \(path)")
    try expect(abs(position - 1.0) < 0.0001, "position came back as \(position)")

    // Pickup must report a reason rather than silence.
    PhotonControl.resetPickup(handle: handle)
    guard case .ignored(.awaitingPickup) = PhotonControl.event(
        handle: handle, source: fader, value: .midi7(127), currentPosition: 0.1)
    else { throw ControlProbeError.failed("a reset fader should await pickup") }

    // Actions, with operands intact, and no second fire on release.
    try expect(PhotonControl.arm(handle: handle, action: .triggerCell(layer: 2, column: 5)),
               "arming an action failed")
    let pad = ControlSource.midiNote(channel: 0, note: 36)
    _ = PhotonControl.event(handle: handle, source: pad, value: .noteOn(velocity: 100))
    guard case .action(.triggerCell(let layer, let column)) = PhotonControl.event(
        handle: handle, source: pad, value: .noteOn(velocity: 100))
    else { throw ControlProbeError.failed("the pad should have fired its action") }
    try expect(layer == 2 && column == 5, "operands came back as \(layer)/\(column)")
    guard case .ignored(.release) = PhotonControl.event(
        handle: handle, source: pad, value: .noteOn(velocity: 0))
    else { throw ControlProbeError.failed("velocity 0 is a release and must not re-fire") }

    // A rebind must name what it displaced.
    try expect(PhotonControl.arm(handle: handle, action: .blackout), "arming blackout failed")
    guard case .learned(let stolen) = PhotonControl.event(
        handle: handle, source: pad, value: .noteOn(velocity: 100))
    else { throw ControlProbeError.failed("the pad should have rebound") }
    try expect(stolen != nil, "a rebind must say what it took the pad away from")

    // The map round-trips as JSON.
    guard let json = PhotonControl.map(handle: handle) else {
        throw ControlProbeError.failed("could not read the control map")
    }
    try expect(json.contains("layer.1.opacity"), "the saved map lost its binding")

    guard let fresh = photon_create(120) else {
        throw ControlProbeError.failed("could not create a second handle")
    }
    defer { photon_destroy(fresh) }
    if let reason = PhotonControl.loadMap(handle: fresh, json: json) {
        throw ControlProbeError.failed("loading a saved map failed: \(reason)")
    }
    try expect(PhotonControl.bindingCount(handle: fresh) == 2,
               "expected both bindings after load, got \(PhotonControl.bindingCount(handle: fresh))")

    // And a corrupt map is refused with something readable.
    let reason = PhotonControl.loadMap(handle: fresh, json: "{ not json")
    try expect((reason?.count ?? 0) > 10, "a refused map must explain itself")

    // Unbinding is exact.
    try expect(PhotonControl.unbind(handle: fresh, source: fader), "unbind should have removed one")
    try expect(!PhotonControl.unbind(handle: fresh, source: fader), "unbinding twice must say no")
}

// The owned-handle session: the object the app actually holds.
//
// Separate from the raw-pointer checks above because the failure modes differ —
// here it is ownership, queue bounds, and whether the thing is usable at all.
func checkSession() throws {
    guard let session = PhotonCoreSession(bpm: 128) else {
        throw ControlProbeError.failed("could not create a session")
    }

    // Musical time advances, and the layer stack survives the crossing.
    session.setLayers([
        CoreLayer(id: 1, opacity: 0.5, textureSlot: 0),
        CoreLayer(id: 2, blend: 3, opacity: 1, textureSlot: 1, position: 0.25),
    ])
    let frame = session.tick(deltaNanos: 250_000_000)   // a quarter second
    try expect(frame.layerCount == 2, "expected 2 layers, got \(frame.layerCount)")
    try expect(abs(frame.bpm - 128) < 0.001, "bpm came back as \(frame.bpm)")
    // 128 BPM for 0.25s is 128/60 * 0.25 beats.
    try expect(abs(frame.beat - (128.0 / 60.0 * 0.25)) < 0.0001,
               "beat came back as \(frame.beat)")

    // Reading the packed array in place, which is the point of packing it.
    let total = session.tick(deltaNanos: 16_666_667) { layers, _ in
        layers.reduce(Float(0)) { $0 + $1.opacity }
    }
    try expect(total > 0, "layer opacities did not survive the crossing")

    // The inbox hands events from other threads to the render thread.
    let fader = ControlSource.midiCC(channel: 0, cc: 7)
    session.arm(parameter: "layer.1.opacity")
    session.enqueue(source: fader, value: .midi7(0))
    session.enqueue(source: fader, value: .midi7(120))
    let outcomes = session.drainControl()
    try expect(outcomes.count == 2, "expected 2 outcomes, got \(outcomes.count)")
    guard case .learned = outcomes[1] else {
        throw ControlProbeError.failed("the queued move should have completed a learn")
    }
    try expect(session.drainControl().isEmpty, "draining twice should yield nothing")
    try expect(session.boundPath(for: fader) == "layer.1.opacity",
               "the bound path did not come back")

    // Pickup gets a real value to compare against, via the bound path.
    session.resetPickup()
    session.enqueue(source: fader, value: .midi7(127))
    let held = session.drainControl { path in path == "layer.1.opacity" ? 0.1 : nil }
    guard case .ignored(.awaitingPickup) = held.first else {
        throw ControlProbeError.failed("pickup should have held the fader")
    }

    // The queue is bounded, and keeps the NEWEST readings — an operator's hand
    // is where it is now, not where it was 500 messages ago.
    for i in 0..<(PhotonCoreSession.maxPending + 100) {
        session.enqueue(source: fader, value: .midi7(UInt8(i % 128)))
    }
    let flood = session.drainControl()
    try expect(flood.count == PhotonCoreSession.maxPending,
               "flood should be bounded at \(PhotonCoreSession.maxPending), got \(flood.count)")
}

// Audio reactivity: the core decides which bands exist, the shell computes them.
func checkAudioReactivity() throws {
    guard let session = PhotonCoreSession(bpm: 120) else {
        throw ControlProbeError.failed("could not create a session")
    }
    session.setLayers([CoreLayer(id: 1, opacity: 1, textureSlot: 0),
                       CoreLayer(id: 2, opacity: 1, textureSlot: 1)])

    try expect(session.audioBands.isEmpty, "nothing bound should mean no filter bank at all")

    try expect(session.bindAudio(parameter: "layer.0.opacity", lowHz: 20, highHz: 160),
               "binding the low band failed")
    try expect(session.bindAudio(parameter: "layer.1.opacity", lowHz: 4000, highHz: 16000),
               "binding the high band failed")

    let bands = session.audioBands
    try expect(bands.count == 2, "expected 2 bands, got \(bands.count)")
    try expect(abs(bands[0].low - 20) < 0.01 && abs(bands[0].high - 160) < 0.01,
               "low band came back as \(bands[0])")

    // A loud low band should raise the layer it drives.
    session.setAudioBands([1.0, 0.0])
    let frame = session.tick(deltaNanos: 500_000_000)
    try expect(frame.layerCount == 2, "lost the layer stack")
    let opacities = session.tick(deltaNanos: 16_666_667) { layers, _ in
        layers.map(\.opacity)
    }
    try expect(opacities[0] > 0.1,
               "a loud low band should raise layer 0, got \(opacities[0])")

    // Nonsense ranges are refused rather than quietly producing a dead band.
    try expect(!session.bindAudio(parameter: "layer.0.opacity", lowHz: 160, highHz: 20),
               "an inverted range should be refused")
    try expect(!session.bindAudio(parameter: "layer.0.opacity", lowHz: .nan, highHz: 100),
               "a NaN edge should be refused")

    try expect(session.unbindAudio(parameter: "layer.0.opacity"), "unbind failed")
    try expect(session.audioBands.count == 1, "unbind removed the wrong number")
}
