import PhotonFFI

enum CoreProbeError: Error { case creationFailed, fieldLayoutMismatch }

/// Stride alone cannot catch same-size field reordering. Exercise the actual
/// imported C structs with distinct sentinel values and a private test handle.
func checkFrameRoundTrip() throws {
    guard let handle = photon_create(120) else { throw CoreProbeError.creationFailed }
    defer { photon_destroy(handle) }
    var input = PhotonLayer(id: 0x010203, blend: 3, opacity: 0.625,
                            tex_slot: 7, position: 0.125, active: 1)
    photon_set_layers(handle, &input, 1)
    let frame = photon_tick(handle, 250_000_000)
    guard frame.layer_count == 1, let pointer = frame.layers else { throw CoreProbeError.fieldLayoutMismatch }
    // Consume before another tick, mutation or handle destruction.
    let result = pointer.pointee
    guard result.id == input.id, result.blend == input.blend,
          result.opacity == input.opacity, result.tex_slot == input.tex_slot,
          result.position == input.position, result.active == input.active,
          abs(frame.beat - 0.5) < 0.000001, abs(frame.phase - 0.5) < 0.000001,
          frame.bpm == 120, frame.frame_index == 1 else { throw CoreProbeError.fieldLayoutMismatch }
}
