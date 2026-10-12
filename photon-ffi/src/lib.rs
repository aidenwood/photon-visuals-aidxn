//! C ABI bridge from `photon-core` to the native shells.
//!
//! **This is the only crate permitted to use `unsafe`.** `photon-core` keeps
//! `#![forbid(unsafe_code)]` and stays portable; every platform boundary lives
//! here, so the Windows shell links the same core through the same bridge.
//!
//! ## The one rule that matters: cross once per frame, not once per layer
//!
//! An FFI call is cheap individually and ruinous in a loop. At 12 layers and
//! 120fps, per-layer calls would be 1,440 crossings a second plus whatever
//! marshalling each one implies. Instead the shell makes **one** call per frame
//! and receives a **packed, immutable snapshot** it can read directly as a C
//! array — no allocation, no per-item conversion, no string parsing.
//!
//! That is why [`PhotonFrame`] is `#[repr(C)]` plain-old-data and the layer
//! array is a raw pointer into memory the core owns: the shell reads it in
//! place for the duration of the frame and never copies it.
//!
//! ## Lifetimes
//!
//! Pointers handed out by [`photon_tick`] are valid **until the next call to
//! `photon_tick` on the same handle**. The shell must consume them within the
//! frame. This is stated here because getting it wrong produces intermittent
//! corruption rather than a clean crash.

use photon_core::clock::Clock;
use photon_core::doc::{Curve, LfoShape, ModSource, Rational, TempoSource};
use photon_core::learn::{
    Action, ControlMap, ControlRouter, ControlSource, ControlValue, Ignored, Routed, Target,
};
use photon_core::modulation::{Binding, ModulationEngine, ModulatorId, ParamId, ParamSpec, Bounds, FrameTime};

/// Opaque engine handle held by the shell.
pub struct PhotonCore {
    clock: Clock,
    layers: Vec<PhotonLayer>,
    frames: u64,
    /// Modulation runs in the core, not the shell: beat sync, audio reactivity
    /// and MIDI are one mechanism and must stay on one side of the boundary.
    modulation: ModulationEngine,
    /// One opacity parameter per layer, resolved to a dense id at bind time so
    /// the frame loop never looks anything up by string.
    opacity_params: Vec<ParamId>,
    /// Beat-synced LFO handle, re-created whenever the stack is rebuilt.
    beat_lfo: Option<ModulatorId>,
    /// Whether the operator wants the LFO at all — kept separate from the
    /// handle, which is invalidated on every stack edit.
    lfo_enabled: bool,
    lfo_beats: f64,
    /// Control mapping and learn mode. Lives here rather than in the shell so
    /// one map serves MIDI, OSC, keys and the remote, on both platforms.
    control: ControlRouter,
    /// Audio-reactive bindings, held as **intent** rather than as live
    /// modulator slots. A stack edit rebuilds the modulation engine from
    /// scratch; without this, mapping the bass to a layer and then adding a
    /// layer would silently stop the mapping working.
    audio_bindings: Vec<AudioBinding>,
    /// Strings handed to the shell by the last control call. Held so the
    /// pointers stay valid for the duration of that call's result.
    control_strings: Vec<std::ffi::CString>,
}

/// One layer, packed for direct reading by the shell.
///
/// Field order and types are part of the ABI — the Swift mirror must match
/// exactly. A mismatch shows up as subtly wrong values, not a clean failure.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PhotonLayer {
    /// Stable layer id.
    pub id: u32,
    /// Blend mode, matching `BlendMode`'s discriminant.
    pub blend: i32,
    /// 0..1 after modulation and master opacity.
    pub opacity: f32,
    /// Index into the shell's bound texture array, or -1.
    pub tex_slot: i32,
    /// Normalised playback position, 0..1.
    pub position: f32,
    /// Non-zero if the layer should be sampled at all.
    pub active: u32,
}

/// An immutable per-frame snapshot.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PhotonFrame {
    /// Pointer to `layer_count` contiguous [`PhotonLayer`] values.
    ///
    /// Valid until the next `photon_tick` on this handle.
    pub layers: *const PhotonLayer,
    /// Number of layers.
    pub layer_count: u32,
    /// Continuous beat position.
    pub beat: f64,
    /// Beat phase, 0..1 — what a beat-synced visual actually reads.
    pub phase: f32,
    /// Current tempo.
    pub bpm: f32,
    /// Frames produced since creation, for drift checks.
    pub frame_index: u64,
}

/// Creates an engine. Returns null on failure.
///
/// # Safety
/// The returned pointer must be released with [`photon_destroy`] exactly once.
#[no_mangle]
pub extern "C" fn photon_create(bpm: f32) -> *mut PhotonCore {
    let mut clock = Clock::new(f64::from(bpm.max(1.0)));
    // The clock is stopped on construction; the engine is always running.
    clock.start(0.0);
    let core = Box::new(PhotonCore {
        clock,
        layers: Vec::with_capacity(32),
        frames: 0,
        modulation: ModulationEngine::new(),
        opacity_params: Vec::with_capacity(32),
        beat_lfo: None,
        lfo_enabled: false,
        lfo_beats: 4.0,
        control: ControlRouter::new(),
        audio_bindings: Vec::new(),
        control_strings: Vec::new(),
    });
    Box::into_raw(core)
}

/// Releases an engine created by [`photon_create`].
///
/// # Safety
/// `handle` must come from [`photon_create`] and must not be used afterwards.
/// Passing null is safe and does nothing.
#[no_mangle]
pub unsafe extern "C" fn photon_destroy(handle: *mut PhotonCore) {
    if handle.is_null() {
        return;
    }
    drop(unsafe { Box::from_raw(handle) });
}

/// Replaces the layer stack.
///
/// Called on edits, **not** per frame.
///
/// # Safety
/// `layers` must point to `count` valid [`PhotonLayer`] values, or be null when
/// `count` is 0. `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn photon_set_layers(
    handle: *mut PhotonCore,
    layers: *const PhotonLayer,
    count: u32,
) {
    let Some(core) = (unsafe { handle.as_mut() }) else {
        return;
    };
    core.layers.clear();
    if layers.is_null() || count == 0 {
        return;
    }
    let slice = unsafe { std::slice::from_raw_parts(layers, count as usize) };
    core.layers.extend_from_slice(slice);
    rebuild_modulation(core);
}

/// One audio-reactive binding, as the operator declared it.
#[derive(Debug, Clone)]
struct AudioBinding {
    path: String,
    low_hz: f64,
    high_hz: f64,
    attack_ms: f64,
    release_ms: f64,
    depth: f64,
    invert: bool,
}

/// Re-registers one opacity parameter per layer and re-binds the LFO.
///
/// Called on stack edits only. Paths are readable and persist; they resolve to
/// dense [`ParamId`]s here so the frame loop never parses a string.
fn rebuild_modulation(core: &mut PhotonCore) {
    core.modulation = ModulationEngine::new();
    core.opacity_params.clear();

    for (i, layer) in core.layers.iter().enumerate() {
        let spec = ParamSpec::new(Bounds::new(0.0, 1.0).expect("0..1 is a valid range"))
            .with_base(f64::from(layer.opacity));
        let id = core.modulation.register(&format!("layer.{i}.opacity"), spec);
        core.opacity_params.push(id);
    }

    core.beat_lfo = None;
    if core.lfo_enabled {
        let lfo = core.modulation.add_source(&ModSource::BeatLfo {
            shape: LfoShape::Sine,
            beats: core.lfo_beats,
            phase: 0.0,
        });
        core.beat_lfo = Some(lfo);
        for &param in &core.opacity_params {
            let _ = core.modulation.bind(Binding {
                param,
                modulator: lfo,
                depth: 1.0,
                offset: 0.0,
                curve: Curve::Linear,
                invert: false,
            });
        }
    }

    // Replay declared audio bindings. A binding whose parameter no longer
    // exists is **dropped silently here on purpose** — the layer it referred to
    // is gone, and the declaration is kept so that re-adding the layer restores
    // the mapping rather than requiring it to be made again.
    let declared = std::mem::take(&mut core.audio_bindings);
    for b in &declared {
        let Some(param) = core.modulation.params().resolve(&b.path) else {
            continue;
        };
        let source = core.modulation.add_source(&ModSource::AudioBand {
            low_hz: b.low_hz,
            high_hz: b.high_hz,
            attack_ms: b.attack_ms,
            release_ms: b.release_ms,
        });
        let _ = core.modulation.bind(Binding {
            param,
            modulator: source,
            depth: b.depth,
            offset: 0.0,
            curve: Curve::Linear,
            invert: b.invert,
        });
    }
    core.audio_bindings = declared;
}

// ── audio reactivity ────────────────────────────────────────────────────────
//
// The core decides **which frequency bands exist**, because the bindings are
// what need them — there is no point running a filter bank nobody reads. The
// shell asks for the list, computes exactly those, and pushes the values back.
//
// It pushes **raw band energy, not an envelope.** The attack and release live
// in the core, with the binding, so they are shared with the Windows shell and
// so a value is smoothed once. Smoothing on both sides is not twice as smooth,
// it is laggy and mushy, and it is the kind of fault that gets blamed on the
// audio interface.

/// Binds an audio band to a parameter.
///
/// `depth` is in normalised sweep space: 1.0 means the band drives the
/// parameter's full start/stop range.
///
/// Returns false if the path is unreadable or the frequency range is nonsense.
/// The binding is **declared**, so it survives stack edits and is restored if
/// a missing layer comes back.
///
/// # Safety
/// `handle` must be valid; `param_path` a NUL-terminated UTF-8 string.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn photon_bind_audio(
    handle: *mut PhotonCore,
    param_path: *const std::os::raw::c_char,
    low_hz: f32,
    high_hz: f32,
    attack_ms: f32,
    release_ms: f32,
    depth: f32,
    invert: bool,
) -> bool {
    let (Some(core), Some(path)) = (unsafe { handle.as_mut() }, read_str(param_path)) else {
        return false;
    };
    if !low_hz.is_finite() || !high_hz.is_finite() || low_hz < 0.0 || high_hz <= low_hz {
        return false;
    }
    // Re-binding the same parameter to a band replaces it rather than stacking
    // a second one: an operator dragging a band onto a fader twice means "this
    // one", not "both at once".
    core.audio_bindings.retain(|b| b.path != path);
    core.audio_bindings.push(AudioBinding {
        path: path.to_owned(),
        low_hz: f64::from(low_hz),
        high_hz: f64::from(high_hz),
        attack_ms: f64::from(attack_ms.max(0.0)),
        release_ms: f64::from(release_ms.max(0.0)),
        depth: f64::from(depth),
        invert,
    });
    rebuild_modulation(core);
    true
}

/// Removes every audio binding on a parameter. True if one was removed.
///
/// # Safety
/// `handle` must be valid; `param_path` a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn photon_unbind_audio(
    handle: *mut PhotonCore,
    param_path: *const std::os::raw::c_char,
) -> bool {
    let (Some(core), Some(path)) = (unsafe { handle.as_mut() }, read_str(param_path)) else {
        return false;
    };
    let before = core.audio_bindings.len();
    core.audio_bindings.retain(|b| b.path != path);
    let removed = core.audio_bindings.len() != before;
    if removed {
        rebuild_modulation(core);
    }
    removed
}

/// How many frequency bands the analyser should compute.
///
/// # Safety
/// `handle` must be valid or null.
#[no_mangle]
pub unsafe extern "C" fn photon_audio_band_count(handle: *const PhotonCore) -> u32 {
    unsafe { handle.as_ref() }.map_or(0, |c| c.modulation.audio_bands().count() as u32)
}

/// Reads one band's frequency range. False if `index` is out of range.
///
/// # Safety
/// `handle` must be valid; `low_hz` and `high_hz` must be writable.
#[no_mangle]
pub unsafe extern "C" fn photon_audio_band(
    handle: *const PhotonCore,
    index: u32,
    low_hz: *mut f32,
    high_hz: *mut f32,
) -> bool {
    let Some(core) = (unsafe { handle.as_ref() }) else {
        return false;
    };
    let Some((lo, hi, _)) = core.modulation.audio_bands().nth(index as usize) else {
        return false;
    };
    if low_hz.is_null() || high_hz.is_null() {
        return false;
    }
    unsafe {
        *low_hz = lo as f32;
        *high_hz = hi as f32;
    }
    true
}

/// Pushes one band's **raw energy**, 0–1. Called every frame.
///
/// Raw, not enveloped: the attack and release belong to the binding, in the
/// core, so they are shared with the Windows shell and applied exactly once.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn photon_set_audio_band(
    handle: *mut PhotonCore,
    index: u32,
    value: f32,
) -> bool {
    let Some(core) = (unsafe { handle.as_mut() }) else {
        return false;
    };
    let Some((_, _, slot)) = core.modulation.audio_bands().nth(index as usize) else {
        return false;
    };
    core.modulation.set_input(slot, f64::from(value));
    true
}

/// Enables or disables a beat-synced opacity LFO across all layers.
///
/// `beats` is the LFO period in musical time, so it stays locked to tempo
/// rather than drifting against it.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn photon_set_beat_lfo(handle: *mut PhotonCore, enabled: bool, beats: f32) {
    let Some(core) = (unsafe { handle.as_mut() }) else { return };
    core.lfo_beats = f64::from(beats.max(0.125));
    core.lfo_enabled = enabled;
    rebuild_modulation(core);
}

/// Advances the engine by `dt_nanos` and returns this frame's snapshot.
///
/// **This is the only call in the frame loop.** One crossing per frame.
///
/// # Safety
/// `handle` must be valid. The returned `layers` pointer is valid only until
/// the next call to this function on the same handle.
#[no_mangle]
pub unsafe extern "C" fn photon_tick(handle: *mut PhotonCore, dt_nanos: u64) -> PhotonFrame {
    let Some(core) = (unsafe { handle.as_mut() }) else {
        return PhotonFrame {
            layers: std::ptr::null(),
            layer_count: 0,
            beat: 0.0,
            phase: 0.0,
            bpm: 0.0,
            frame_index: 0,
        };
    };

    let dt = dt_nanos as f64 / 1_000_000_000.0;
    core.clock.advance_by(dt);
    core.frames += 1;

    // Musical time as an exact ratio, not a float — the modulation engine
    // takes a Rational precisely so a long set cannot accumulate drift.
    let beats = core.clock.beats_after(0.0);
    let beat_exact = Rational::new((beats * 1_000_000.0) as i64, 1_000_000);
    core.modulation.evaluate(FrameTime::new(beat_exact, dt));

    for (i, param) in core.opacity_params.iter().enumerate() {
        if let (Some(v), Some(layer)) = (core.modulation.value(*param), core.layers.get_mut(i)) {
            layer.opacity = v as f32;
        }
    }

    PhotonFrame {
        layers: core.layers.as_ptr(),
        layer_count: core.layers.len() as u32,
        beat: core.clock.beats_after(0.0),
        phase: core.clock.beat_phase() as f32,
        bpm: (core.clock.beats_per_second() * 60.0) as f32,
        frame_index: core.frames,
    }
}

/// Sets tempo directly.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn photon_set_bpm(handle: *mut PhotonCore, bpm: f32) {
    if let Some(core) = unsafe { handle.as_mut() } {
        // Attributed to a source: tempo and phase are separable, and the
        // clock rejects implausible runtime tempo rather than following it.
        core.clock.set_bpm(TempoSource::Manual, f64::from(bpm.max(1.0)));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Document — the `.photon` schema stays in Rust; the shell handles opaque JSON.
// ─────────────────────────────────────────────────────────────────────────────
//
// The shell never models the document. It passes JSON in and gets JSON out, and
// **Rust is the only thing that knows the schema**. That is what stops a Swift
// mirror and a Rust definition drifting apart — a fork of the document format
// would mean a project saved by the Mac app failing to open on Windows, which
// is a product failure rather than a maintenance annoyance.

/// Result of a document operation. Owned by the caller; free with
/// [`photon_string_free`].
#[repr(C)]
pub struct PhotonString {
    /// NUL-terminated UTF-8, or null on failure.
    pub ptr: *mut std::os::raw::c_char,
    /// Length excluding the NUL.
    pub len: u32,
    /// Non-zero if the operation succeeded.
    pub ok: u32,
}

fn make_string(s: &str, ok: bool) -> PhotonString {
    match std::ffi::CString::new(s) {
        Ok(c) => {
            let len = c.as_bytes().len() as u32;
            PhotonString { ptr: c.into_raw(), len, ok: u32::from(ok) }
        }
        Err(_) => PhotonString { ptr: std::ptr::null_mut(), len: 0, ok: 0 },
    }
}

/// Frees a string returned by this API.
///
/// # Safety
/// `s.ptr` must come from this API and must not be used afterwards.
#[no_mangle]
pub unsafe extern "C" fn photon_string_free(s: PhotonString) {
    if !s.ptr.is_null() {
        drop(unsafe { std::ffi::CString::from_raw(s.ptr) });
    }
}

/// A new empty document, as JSON.
#[no_mangle]
pub extern "C" fn photon_document_default() -> PhotonString {
    use photon_core::doc::*;
    let doc = Document {
        schema_version: SCHEMA_VERSION,
        meta: Meta {
            name: "Untitled".into(),
            created: String::new(),
            modified: String::new(),
            written_by: crate::VERSION_STR.into(),
        },
        composition: Composition {
            width: 1920,
            height: 1080,
            rate: Rational::FPS_60,
            working_space: WorkingSpace::default(),
        },
        clock: ClockConfig {
            bpm: 120.0,
            tempo_source: TempoSource::default(),
            phase_source: PhaseSource::default(),
            quantise: Quantise::default(),
        },
        layers: vec![],
        clips: vec![],
        sources: vec![],
        modulation: vec![],
    };
    match serde_json::to_string_pretty(&doc) {
        Ok(j) => make_string(&j, true),
        Err(e) => make_string(&format!("serialise failed: {e}"), false),
    }
}

/// Validates document JSON against the schema.
///
/// Returns `ok = 1` and an empty string on success, or `ok = 0` and a
/// human-readable reason. **The reason matters**: a document that fails to open
/// with "invalid" tells an operator nothing, and they are usually standing in a
/// venue when it happens.
///
/// # Safety
/// `json` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn photon_document_validate(
    json: *const std::os::raw::c_char,
) -> PhotonString {
    if json.is_null() {
        return make_string("null document", false);
    }
    let text = match unsafe { std::ffi::CStr::from_ptr(json) }.to_str() {
        Ok(t) => t,
        Err(_) => return make_string("document is not valid UTF-8", false),
    };
    match serde_json::from_str::<photon_core::doc::Document>(text) {
        Ok(doc) => {
            if doc.schema_version > photon_core::doc::SCHEMA_VERSION {
                make_string(
                    &format!(
                        "document is schema v{} but this build understands v{} — it was saved by a newer version",
                        doc.schema_version,
                        photon_core::doc::SCHEMA_VERSION
                    ),
                    false,
                )
            } else {
                make_string("", true)
            }
        }
        Err(e) => make_string(&format!("{e}"), false),
    }
}

/// Round-trips a document through the schema, normalising it.
///
/// # Safety
/// `json` must be a valid NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn photon_document_normalise(
    json: *const std::os::raw::c_char,
) -> PhotonString {
    if json.is_null() {
        return make_string("null document", false);
    }
    let text = match unsafe { std::ffi::CStr::from_ptr(json) }.to_str() {
        Ok(t) => t,
        Err(_) => return make_string("document is not valid UTF-8", false),
    };
    match serde_json::from_str::<photon_core::doc::Document>(text)
        .and_then(|d| serde_json::to_string_pretty(&d))
    {
        Ok(j) => make_string(&j, true),
        Err(e) => make_string(&format!("{e}"), false),
    }
}


// ── control mapping and learn ───────────────────────────────────────────────
//
// Control is **not** the frame loop: a busy desk sends a few hundred events a
// second, against 480 layer-frames. It still crosses as packed structs rather
// than JSON, for a different reason — a JSON outcome would need a Swift type to
// decode into, and that type would be a **second definition of the mapping
// schema**, free to drift from the Rust one. Discriminants are cheap; a forked
// schema is not.
//
// Saving and loading the map *is* JSON, because there the schema is the file
// format and Rust is unambiguously its owner.
//
// The shell owns transport (CoreMIDI, WinMM, a UDP socket) and decodes a raw
// message into a source and a value. Everything after that is here.

/// Source kinds. **ABI** — the header mirrors these values.
pub mod source_kind {
    /// MIDI continuous controller.
    pub const MIDI_CC: i32 = 0;
    /// MIDI note / pad.
    pub const MIDI_NOTE: i32 = 1;
    /// MIDI pitch wheel.
    pub const MIDI_PITCH_BEND: i32 = 2;
    /// OSC address.
    pub const OSC: i32 = 3;
    /// Computer keyboard key.
    pub const KEY: i32 = 4;
}

/// Value resolutions. **ABI.**
pub mod value_kind {
    /// 7-bit MIDI, 0–127, carried in `value`.
    pub const MIDI7: i32 = 0;
    /// 14-bit pitch bend, 0–16383.
    pub const MIDI14: i32 = 1;
    /// Already normalised, 0–1.
    pub const UNIT: i32 = 2;
    /// Press (non-zero) or release (zero).
    pub const GATE: i32 = 3;
}

/// Action discriminants. **ABI.**
pub mod action_kind {
    /// Fire one cell; `a` = layer, `b` = column.
    pub const TRIGGER_CELL: i32 = 0;
    /// Fire a column; `a` = column.
    pub const TRIGGER_COLUMN: i32 = 1;
    /// Stop a layer; `a` = layer.
    pub const CLEAR_LAYER: i32 = 2;
    /// Advance the cue list.
    pub const CUE_GO: i32 = 3;
    /// Kill output.
    pub const BLACKOUT: i32 = 4;
    /// One tempo tap.
    pub const TAP_TEMPO: i32 = 5;
    /// Resync the beat grid.
    pub const RESYNC: i32 = 6;
}

/// Routed outcome kinds. **ABI.**
pub mod routed_kind {
    /// Nothing happened; see `ignored`.
    pub const IGNORED: i32 = 0;
    /// Move a parameter; see `path` and `position`.
    pub const PARAMETER: i32 = 1;
    /// Fire an action; see `action`, `a`, `b`.
    pub const ACTION: i32 = 2;
    /// Learn is armed and waiting for movement.
    pub const LEARNING: i32 = 3;
    /// Learn captured this control.
    pub const LEARNED: i32 = 4;
}

/// Reasons an event produced nothing. **ABI.**
pub mod ignored_reason {
    /// Nothing is bound to this control.
    pub const UNBOUND: i32 = 0;
    /// A release on a control that only acts on press.
    pub const RELEASE: i32 = 1;
    /// Pickup engaged — the control has not reached the current value yet.
    pub const AWAITING_PICKUP: i32 = 2;
}

/// A physical control, as the shell decoded it.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PhotonControlSource {
    /// One of [`source_kind`].
    pub kind: i32,
    /// MIDI channel, 0-based. Ignored for OSC and keys.
    pub channel: u8,
    /// Controller or note number. Ignored for pitch bend, OSC and keys.
    pub number: u8,
    /// OSC address or key code, NUL-terminated UTF-8. Null otherwise.
    pub text: *const std::os::raw::c_char,
}

/// The outcome of one control event.
///
/// `path` points into memory owned by the core and is valid **until the next
/// control call on the same handle** — the same lifetime rule as
/// [`PhotonFrame`], stated here because getting it wrong produces intermittent
/// corruption rather than a clean crash.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct PhotonRouted {
    /// One of [`routed_kind`].
    pub kind: i32,
    /// One of [`ignored_reason`], when `kind` is `IGNORED`.
    pub ignored: i32,
    /// Position into the parameter's sweep, 0–1, when `kind` is `PARAMETER`.
    pub position: f32,
    /// One of [`action_kind`], when `kind` is `ACTION`.
    pub action: i32,
    /// First action operand — layer, or column for `TRIGGER_COLUMN`.
    pub a: u32,
    /// Second action operand — column for `TRIGGER_CELL`.
    pub b: u32,
    /// Parameter path when `kind` is `PARAMETER`, else null.
    pub path: *const std::os::raw::c_char,
    /// Non-zero when a learn displaced an existing binding. **Show this** — a
    /// pad silently stolen from blackout is how a show loses its panic button.
    pub displaced: u32,
    /// Readable description of what was displaced, or null.
    pub displaced_label: *const std::os::raw::c_char,
}

impl PhotonRouted {
    fn empty(kind: i32) -> Self {
        Self {
            kind,
            ignored: 0,
            position: 0.0,
            action: 0,
            a: 0,
            b: 0,
            path: std::ptr::null(),
            displaced: 0,
            displaced_label: std::ptr::null(),
        }
    }
}

fn read_str<'a>(p: *const std::os::raw::c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { std::ffi::CStr::from_ptr(p) }.to_str().ok()
}

impl PhotonControlSource {
    fn decode(self) -> Option<ControlSource> {
        Some(match self.kind {
            source_kind::MIDI_CC => ControlSource::MidiCc {
                channel: self.channel,
                cc: self.number,
            },
            source_kind::MIDI_NOTE => ControlSource::MidiNote {
                channel: self.channel,
                note: self.number,
            },
            source_kind::MIDI_PITCH_BEND => ControlSource::MidiPitchBend {
                channel: self.channel,
            },
            source_kind::OSC => ControlSource::Osc {
                address: read_str(self.text)?.to_owned(),
            },
            source_kind::KEY => ControlSource::Key {
                code: read_str(self.text)?.to_owned(),
            },
            _ => return None,
        })
    }
}

fn decode_action(action: i32, a: u32, b: u32) -> Option<Action> {
    Some(match action {
        action_kind::TRIGGER_CELL => Action::TriggerCell { layer: a, column: b },
        action_kind::TRIGGER_COLUMN => Action::TriggerColumn { column: a },
        action_kind::CLEAR_LAYER => Action::ClearLayer { layer: a },
        action_kind::CUE_GO => Action::CueGo,
        action_kind::BLACKOUT => Action::Blackout,
        action_kind::TAP_TEMPO => Action::TapTempo,
        action_kind::RESYNC => Action::Resync,
        _ => return None,
    })
}

fn encode_action(action: &Action) -> (i32, u32, u32) {
    match action {
        Action::TriggerCell { layer, column } => (action_kind::TRIGGER_CELL, *layer, *column),
        Action::TriggerColumn { column } => (action_kind::TRIGGER_COLUMN, *column, 0),
        Action::ClearLayer { layer } => (action_kind::CLEAR_LAYER, *layer, 0),
        Action::CueGo => (action_kind::CUE_GO, 0, 0),
        Action::Blackout => (action_kind::BLACKOUT, 0, 0),
        Action::TapTempo => (action_kind::TAP_TEMPO, 0, 0),
        Action::Resync => (action_kind::RESYNC, 0, 0),
    }
}

/// Arms learn mode for a parameter. The next control that **moves** binds to it.
///
/// Returns false if the path is unreadable.
///
/// # Safety
/// `handle` must be valid; `path` a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn photon_control_arm_parameter(
    handle: *mut PhotonCore,
    path: *const std::os::raw::c_char,
) -> bool {
    let (Some(core), Some(path)) = (unsafe { handle.as_mut() }, read_str(path)) else {
        return false;
    };
    core.control.arm(Target::parameter(path));
    true
}

/// Arms learn mode for an action.
///
/// # Safety
/// `handle` must be valid.
#[no_mangle]
pub unsafe extern "C" fn photon_control_arm_action(
    handle: *mut PhotonCore,
    action: i32,
    a: u32,
    b: u32,
) -> bool {
    let (Some(core), Some(action)) = (unsafe { handle.as_mut() }, decode_action(action, a, b))
    else {
        return false;
    };
    core.control.arm(Target::Action(action));
    true
}

/// Cancels learn without binding anything.
///
/// # Safety
/// `handle` must be valid or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_disarm(handle: *mut PhotonCore) {
    if let Some(core) = unsafe { handle.as_mut() } {
        core.control.disarm();
    }
}

/// Whether learn is waiting for a control, for the armed indicator.
///
/// # Safety
/// `handle` must be valid or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_is_learning(handle: *const PhotonCore) -> bool {
    unsafe { handle.as_ref() }.is_some_and(|c| c.control.is_learning())
}

/// Feeds one decoded control event.
///
/// `value_kind` is one of [`value_kind`]; `value` carries the raw reading in
/// that resolution. `current_position` is the target parameter's present
/// position, 0–1, which is what pickup compares against — pass a **negative**
/// value for "unknown", since a value nothing knows cannot jump.
///
/// # Safety
/// `handle` must be valid. `source.text` must be NUL-terminated UTF-8 or null.
/// The returned `path` is valid until the next control call on this handle.
#[no_mangle]
pub unsafe extern "C" fn photon_control_event(
    handle: *mut PhotonCore,
    source: PhotonControlSource,
    value_kind: i32,
    value: f32,
    current_position: f32,
) -> PhotonRouted {
    let Some(core) = (unsafe { handle.as_mut() }) else {
        return PhotonRouted::empty(routed_kind::IGNORED);
    };
    let Some(source) = source.decode() else {
        return PhotonRouted::empty(routed_kind::IGNORED);
    };
    let value = match value_kind {
        value_kind::MIDI7 => ControlValue::Midi7(value.clamp(0.0, 127.0) as u8),
        value_kind::MIDI14 => ControlValue::Midi14(value.clamp(0.0, 16383.0) as u16),
        value_kind::GATE => ControlValue::Gate(value != 0.0),
        _ => ControlValue::Unit(f64::from(value)),
    };
    let current = f64::from(current_position);
    let routed = core.control.observe(&source, value, |_| {
        if current < 0.0 {
            None
        } else {
            Some(current)
        }
    });

    // Strings handed out must outlive the call, so they are parked on the
    // handle and replaced on the next one — the same contract as PhotonFrame.
    core.control_strings.clear();
    let mut park = |s: &str| -> *const std::os::raw::c_char {
        match std::ffi::CString::new(s) {
            Ok(c) => {
                let p = c.as_ptr();
                core.control_strings.push(c);
                p
            }
            Err(_) => std::ptr::null(),
        }
    };

    match routed {
        Routed::Learning => PhotonRouted::empty(routed_kind::LEARNING),
        Routed::Learned { displaced, .. } => {
            let mut out = PhotonRouted::empty(routed_kind::LEARNED);
            if let Some(d) = displaced {
                out.displaced = 1;
                out.displaced_label = park(&describe_target(&d.target));
            }
            out
        }
        Routed::Parameter { path, position } => {
            let mut out = PhotonRouted::empty(routed_kind::PARAMETER);
            out.position = position as f32;
            out.path = park(&path);
            out
        }
        Routed::Action(action) => {
            let mut out = PhotonRouted::empty(routed_kind::ACTION);
            let (kind, a, b) = encode_action(&action);
            out.action = kind;
            out.a = a;
            out.b = b;
            out
        }
        Routed::Ignored(reason) => {
            let mut out = PhotonRouted::empty(routed_kind::IGNORED);
            out.ignored = match reason {
                Ignored::Unbound => ignored_reason::UNBOUND,
                Ignored::Release => ignored_reason::RELEASE,
                Ignored::AwaitingPickup => ignored_reason::AWAITING_PICKUP,
            };
            out
        }
    }
}

fn describe_target(target: &Target) -> String {
    match target {
        Target::Parameter { path } => path.clone(),
        Target::Action(a) => format!("{a:?}"),
    }
}

/// The control map as JSON, for saving with the document.
///
/// # Safety
/// `handle` must be valid or null. Free with [`photon_string_free`].
#[no_mangle]
pub unsafe extern "C" fn photon_control_map(handle: *const PhotonCore) -> PhotonString {
    let Some(core) = (unsafe { handle.as_ref() }) else {
        return make_string("null handle", false);
    };
    match serde_json::to_string_pretty(&core.control.map) {
        Ok(j) => make_string(&j, true),
        Err(e) => make_string(&format!("could not write map: {e}"), false),
    }
}

/// Replaces the control map.
///
/// Every control re-earns pickup afterwards: a fader that was live against the
/// old map is, by definition, out of sync with the new one.
///
/// Returns `ok = 1`, or `ok = 0` with a readable reason — a map that fails to
/// load with "invalid" tells an operator nothing, and they are usually standing
/// in a venue when it happens.
///
/// # Safety
/// `handle` must be valid; `json` a NUL-terminated UTF-8 string.
#[no_mangle]
pub unsafe extern "C" fn photon_control_map_load(
    handle: *mut PhotonCore,
    json: *const std::os::raw::c_char,
) -> PhotonString {
    let Some(core) = (unsafe { handle.as_mut() }) else {
        return make_string("null handle", false);
    };
    let Some(text) = read_str(json) else {
        return make_string("map is not valid UTF-8", false);
    };
    match serde_json::from_str::<ControlMap>(text) {
        Ok(m) => {
            core.control = ControlRouter::with_map(m);
            make_string("", true)
        }
        Err(e) => make_string(&format!("could not read map: {e}"), false),
    }
}

/// Removes one binding. Returns true if something was bound.
///
/// # Safety
/// `handle` must be valid; `source.text` NUL-terminated UTF-8 or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_unbind(
    handle: *mut PhotonCore,
    source: PhotonControlSource,
) -> bool {
    let (Some(core), Some(source)) = (unsafe { handle.as_mut() }, source.decode()) else {
        return false;
    };
    core.control.map.unbind(&source).is_some()
}

/// Makes every control re-earn pickup — after a bank switch or a page change.
///
/// # Safety
/// `handle` must be valid or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_reset_pickup(handle: *mut PhotonCore) {
    if let Some(core) = unsafe { handle.as_mut() } {
        core.control.reset_pickup();
    }
}

/// The parameter path a source is bound to, or null.
///
/// Exists so the shell can ask pickup's question — "what value does this
/// control's target currently hold?" — without serialising the whole map. The
/// obvious alternative, reading the saved JSON per event, costs a full encode
/// and parse on **every message of a fader sweep**.
///
/// The returned pointer is owned by the core and valid until the next control
/// call on this handle, like every other string here.
///
/// # Safety
/// `handle` must be valid; `source.text` NUL-terminated UTF-8 or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_bound_path(
    handle: *mut PhotonCore,
    source: PhotonControlSource,
) -> *const std::os::raw::c_char {
    let (Some(core), Some(source)) = (unsafe { handle.as_mut() }, source.decode()) else {
        return std::ptr::null();
    };
    let Some(assignment) = core.control.map.get(&source) else {
        return std::ptr::null();
    };
    let Target::Parameter { path } = &assignment.target else {
        return std::ptr::null();
    };
    let Ok(c) = std::ffi::CString::new(path.as_str()) else {
        return std::ptr::null();
    };
    core.control_strings.clear();
    let p = c.as_ptr();
    core.control_strings.push(c);
    p
}

/// Number of bindings, for a status line.
///
/// # Safety
/// `handle` must be valid or null.
#[no_mangle]
pub unsafe extern "C" fn photon_control_binding_count(handle: *const PhotonCore) -> u32 {
    unsafe { handle.as_ref() }.map_or(0, |c| c.control.map.len() as u32)
}

/// Crate version string, for `written_by`.
pub(crate) const VERSION_STR: &str = env!("CARGO_PKG_VERSION");

/// ABI version. The shell must check this matches what it was built against —
/// a silently mismatched struct layout is the worst class of bug here.
#[no_mangle]
pub extern "C" fn photon_abi_version() -> u32 {
    1
}

/// Size of [`PhotonLayer`], so the shell can assert its mirror matches.
#[no_mangle]
pub extern "C" fn photon_layer_stride() -> u32 {
    core::mem::size_of::<PhotonLayer>() as u32
}

/// Size of [`PhotonFrame`], for the same reason.
#[no_mangle]
pub extern "C" fn photon_frame_stride() -> u32 {
    core::mem::size_of::<PhotonFrame>() as u32
}

/// Size of [`PhotonRouted`], so the shell can assert its mirror matches.
#[no_mangle]
pub extern "C" fn photon_routed_stride() -> u32 {
    core::mem::size_of::<PhotonRouted>() as u32
}

/// Size of [`PhotonControlSource`], for the same reason.
#[no_mangle]
pub extern "C" fn photon_control_source_stride() -> u32 {
    core::mem::size_of::<PhotonControlSource>() as u32
}

/// Unused today, but proves `Rational` crosses the boundary intact when the
/// document model starts flowing through here.
#[no_mangle]
pub extern "C" fn photon_rational_to_f64(num: i64, den: i64) -> f64 {
    if den == 0 {
        return 0.0;
    }
    Rational::new(num, den).to_f64()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn layer(id: u32) -> PhotonLayer {
        PhotonLayer {
            id,
            blend: 0,
            opacity: 1.0,
            tex_slot: -1,
            position: 0.0,
            active: 1,
        }
    }

    #[test]
    fn create_and_destroy_round_trips() {
        let h = photon_create(128.0);
        assert!(!h.is_null());
        unsafe { photon_destroy(h) };
    }

    #[test]
    fn destroy_null_is_safe() {
        unsafe { photon_destroy(std::ptr::null_mut()) };
    }

    #[test]
    fn tick_on_null_returns_an_empty_frame_rather_than_crashing() {
        // A shell bug must not take the process down mid-show.
        let f = unsafe { photon_tick(std::ptr::null_mut(), 1000) };
        assert_eq!(f.layer_count, 0);
        assert!(f.layers.is_null());
    }

    #[test]
    fn layers_survive_the_crossing_unchanged() {
        let h = photon_create(120.0);
        let input = [layer(7), layer(9), layer(11)];
        unsafe { photon_set_layers(h, input.as_ptr(), 3) };

        let f = unsafe { photon_tick(h, 0) };
        assert_eq!(f.layer_count, 3);
        let out = unsafe { std::slice::from_raw_parts(f.layers, 3) };
        assert_eq!(out, &input, "packed layers must cross byte-identical");
        unsafe { photon_destroy(h) };
    }

    #[test]
    fn clearing_layers_is_honoured() {
        let h = photon_create(120.0);
        let input = [layer(1)];
        unsafe { photon_set_layers(h, input.as_ptr(), 1) };
        unsafe { photon_set_layers(h, std::ptr::null(), 0) };
        let f = unsafe { photon_tick(h, 0) };
        assert_eq!(f.layer_count, 0);
        unsafe { photon_destroy(h) };
    }

    #[test]
    fn clock_advances_across_the_boundary() {
        let h = photon_create(120.0);
        // 120 BPM = 2 beats/sec. Half a second must be ~1 beat.
        let f = unsafe { photon_tick(h, 500_000_000) };
        assert!((f.beat - 1.0).abs() < 1e-6, "beat was {}", f.beat);
        assert!((f.bpm - 120.0).abs() < 1e-3);
        unsafe { photon_destroy(h) };
    }

    #[test]
    fn frame_index_is_monotonic() {
        let h = photon_create(120.0);
        let a = unsafe { photon_tick(h, 1000) }.frame_index;
        let b = unsafe { photon_tick(h, 1000) }.frame_index;
        assert_eq!(b, a + 1, "a gap here would mean dropped engine frames");
        unsafe { photon_destroy(h) };
    }

    #[test]
    fn abi_strides_are_stable() {
        // The Swift mirror asserts against these at startup. If this test
        // changes, the Swift side MUST change with it.
        assert_eq!(photon_layer_stride(), 24);
        assert_eq!(photon_abi_version(), 1);
    }

    #[test]
    fn beat_lfo_modulates_opacity_across_a_bar() {
        // Proves modulation actually runs in the core and reaches the packed
        // frame the shell reads — not merely that it compiles.
        let h = photon_create(120.0);           // 2 beats/sec
        let input = [layer(0), layer(1)];
        unsafe { photon_set_layers(h, input.as_ptr(), 2) };
        unsafe { photon_set_beat_lfo(h, true, 4.0) };   // 4-beat period = 2s

        let mut seen: Vec<f32> = Vec::new();
        // Step through two seconds in 60fps-sized steps.
        for _ in 0..120 {
            let f = unsafe { photon_tick(h, 16_666_667) };
            let layers = unsafe { std::slice::from_raw_parts(f.layers, f.layer_count as usize) };
            seen.push(layers[0].opacity);
        }

        let lo = seen.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = seen.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo > 0.5, "LFO should sweep opacity widely, got {lo}..{hi}");
        assert!(lo >= -0.001 && hi <= 1.001, "must stay inside 0..1, got {lo}..{hi}");

        unsafe { photon_destroy(h) };
    }

    #[test]
    fn disabling_the_lfo_leaves_opacity_static() {
        let h = photon_create(120.0);
        let input = [layer(0)];
        unsafe { photon_set_layers(h, input.as_ptr(), 1) };
        unsafe { photon_set_beat_lfo(h, true, 4.0) };
        unsafe { photon_set_beat_lfo(h, false, 4.0) };

        let mut seen: Vec<f32> = Vec::new();
        for _ in 0..60 {
            let f = unsafe { photon_tick(h, 16_666_667) };
            seen.push(unsafe { std::slice::from_raw_parts(f.layers, 1) }[0].opacity);
        }
        let lo = seen.iter().cloned().fold(f32::INFINITY, f32::min);
        let hi = seen.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
        assert!(hi - lo < 1e-6, "opacity must not move once the LFO is off");
        unsafe { photon_destroy(h) };
    }

    fn cstr(s: &str) -> std::ffi::CString { std::ffi::CString::new(s).unwrap() }

    fn read(p: PhotonString) -> (bool, String) {
        let ok = p.ok != 0;
        let text = if p.ptr.is_null() {
            String::new()
        } else {
            unsafe { std::ffi::CStr::from_ptr(p.ptr) }.to_string_lossy().into_owned()
        };
        unsafe { photon_string_free(p) };
        (ok, text)
    }

    #[test]
    fn a_default_document_is_valid_against_its_own_schema() {
        let (ok, json) = read(photon_document_default());
        assert!(ok, "default document failed to serialise: {json}");
        let c = cstr(&json);
        let (valid, why) = read(unsafe { photon_document_validate(c.as_ptr()) });
        assert!(valid, "default document did not validate: {why}");
    }

    #[test]
    fn an_invalid_document_reports_WHY_not_just_that_it_failed() {
        let c = cstr(r#"{"schemaVersion":0,"meta":{}}"#);
        let (ok, why) = read(unsafe { photon_document_validate(c.as_ptr()) });
        assert!(!ok);
        // An operator standing in a venue needs more than "invalid".
        assert!(!why.is_empty(), "no reason given");
        assert!(why.len() > 10, "reason too terse to act on: {why}");
    }

    #[test]
    fn a_document_from_a_newer_build_says_so_plainly() {
        let (_, json) = read(photon_document_default());
        let bumped = json.replace("\"schemaVersion\": 0", "\"schemaVersion\": 99");
        let c = cstr(&bumped);
        let (ok, why) = read(unsafe { photon_document_validate(c.as_ptr()) });
        assert!(!ok);
        assert!(why.contains("newer version"), "unhelpful message: {why}");
    }

    #[test]
    fn documents_round_trip_through_normalisation() {
        let (_, json) = read(photon_document_default());
        let c = cstr(&json);
        let (ok, once) = read(unsafe { photon_document_normalise(c.as_ptr()) });
        assert!(ok, "{once}");
        let c2 = cstr(&once);
        let (ok2, twice) = read(unsafe { photon_document_normalise(c2.as_ptr()) });
        assert!(ok2);
        assert_eq!(once, twice, "normalisation must be idempotent");
    }

    #[test]
    fn malformed_input_never_panics() {
        for bad in ["", "{", "null", "[]", "{\"schemaVersion\":\"x\"}"] {
            let c = cstr(bad);
            let (ok, _) = read(unsafe { photon_document_validate(c.as_ptr()) });
            assert!(!ok, "{bad:?} should not validate");
        }
        let (ok, _) = read(unsafe { photon_document_validate(std::ptr::null()) });
        assert!(!ok, "a null document must not crash");
    }

    #[test]
    fn rational_crosses_intact() {
        // 30000/1001 is the case a float would quietly ruin.
        let v = photon_rational_to_f64(30000, 1001);
        assert!((v - 29.970_029_97).abs() < 1e-6);
        assert_eq!(photon_rational_to_f64(1, 0), 0.0, "div by zero must not panic");
    }

    // ── control mapping across the boundary ─────────────────────────────────

    fn cc_source(cc: u8) -> PhotonControlSource {
        PhotonControlSource {
            kind: source_kind::MIDI_CC,
            channel: 0,
            number: cc,
            text: std::ptr::null(),
        }
    }

    fn note_source(note: u8) -> PhotonControlSource {
        PhotonControlSource {
            kind: source_kind::MIDI_NOTE,
            channel: 0,
            number: note,
            text: std::ptr::null(),
        }
    }

    #[test]
    fn learn_binds_a_fader_and_then_routes_it() {
        unsafe {
            let h = photon_create(120.0);
            let path = std::ffi::CString::new("layer.1.opacity").unwrap();
            assert!(photon_control_arm_parameter(h, path.as_ptr()));
            assert!(photon_control_is_learning(h));

            // Reference reading, then a real move.
            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 0.0, -1.0);
            assert_eq!(r.kind, routed_kind::LEARNING);
            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 100.0, -1.0);
            assert_eq!(r.kind, routed_kind::LEARNED);
            assert_eq!(r.displaced, 0);
            assert!(!photon_control_is_learning(h));
            assert_eq!(photon_control_binding_count(h), 1);

            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 127.0, -1.0);
            assert_eq!(r.kind, routed_kind::PARAMETER);
            assert!((r.position - 1.0).abs() < 1e-6);
            let returned = std::ffi::CStr::from_ptr(r.path).to_str().unwrap();
            assert_eq!(returned, "layer.1.opacity");

            photon_destroy(h);
        }
    }

    #[test]
    fn a_displaced_binding_is_named_across_the_boundary() {
        // The shell has to be able to tell the operator what it just took the
        // pad away from.
        unsafe {
            let h = photon_create(120.0);
            assert!(photon_control_arm_action(h, action_kind::BLACKOUT, 0, 0));
            photon_control_event(h, note_source(36), value_kind::GATE, 1.0, -1.0);

            assert!(photon_control_arm_action(h, action_kind::CUE_GO, 0, 0));
            let r = photon_control_event(h, note_source(36), value_kind::GATE, 1.0, -1.0);
            assert_eq!(r.kind, routed_kind::LEARNED);
            assert_eq!(r.displaced, 1);
            assert!(!r.displaced_label.is_null());
            let label = std::ffi::CStr::from_ptr(r.displaced_label).to_str().unwrap();
            assert!(label.contains("Blackout"), "got {label}");
            photon_destroy(h);
        }
    }

    #[test]
    fn an_action_crosses_with_its_operands_intact() {
        unsafe {
            let h = photon_create(120.0);
            assert!(photon_control_arm_action(h, action_kind::TRIGGER_CELL, 2, 5));
            photon_control_event(h, note_source(40), value_kind::GATE, 1.0, -1.0);

            let r = photon_control_event(h, note_source(40), value_kind::GATE, 1.0, -1.0);
            assert_eq!(r.kind, routed_kind::ACTION);
            assert_eq!(r.action, action_kind::TRIGGER_CELL);
            assert_eq!((r.a, r.b), (2, 5));

            // Release must not fire it a second time.
            let r = photon_control_event(h, note_source(40), value_kind::GATE, 0.0, -1.0);
            assert_eq!(r.kind, routed_kind::IGNORED);
            assert_eq!(r.ignored, ignored_reason::RELEASE);
            photon_destroy(h);
        }
    }

    #[test]
    fn pickup_reaches_the_shell_as_a_reason_not_as_silence() {
        unsafe {
            let h = photon_create(120.0);
            assert!(photon_control_arm_parameter(h, c"a".as_ptr()));
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 0.0, -1.0);
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 100.0, -1.0);

            // Parameter sits at 0.1; fader is at the top.
            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 127.0, 0.1);
            assert_eq!(r.kind, routed_kind::IGNORED);
            assert_eq!(r.ignored, ignored_reason::AWAITING_PICKUP);
            // Passing through 0.1 takes control.
            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 5.0, 0.1);
            assert_eq!(r.kind, routed_kind::PARAMETER);
            photon_destroy(h);
        }
    }

    #[test]
    fn an_unbound_control_reports_unbound_rather_than_nothing() {
        unsafe {
            let h = photon_create(120.0);
            let r = photon_control_event(h, cc_source(7), value_kind::MIDI7, 64.0, -1.0);
            assert_eq!(r.kind, routed_kind::IGNORED);
            assert_eq!(r.ignored, ignored_reason::UNBOUND);
            assert!(r.path.is_null());
            photon_destroy(h);
        }
    }

    #[test]
    fn the_map_survives_a_save_and_load_through_the_boundary() {
        unsafe {
            let h = photon_create(120.0);
            assert!(photon_control_arm_parameter(h, c"layer.1.opacity".as_ptr()));
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 0.0, -1.0);
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 100.0, -1.0);

            let saved = photon_control_map(h);
            assert_eq!(saved.ok, 1);
            let json = std::ffi::CStr::from_ptr(saved.ptr).to_owned();
            photon_destroy(h);

            let h2 = photon_create(120.0);
            assert_eq!(photon_control_binding_count(h2), 0);
            let loaded = photon_control_map_load(h2, json.as_ptr());
            assert_eq!(loaded.ok, 1, "{:?}", std::ffi::CStr::from_ptr(loaded.ptr));
            assert_eq!(photon_control_binding_count(h2), 1);

            photon_string_free(saved);
            photon_string_free(loaded);
            photon_destroy(h2);
        }
    }

    #[test]
    fn a_corrupt_map_is_refused_with_a_readable_reason() {
        // "Invalid" tells an operator nothing, and they are usually standing in
        // a venue when it happens.
        unsafe {
            let h = photon_create(120.0);
            let r = photon_control_map_load(h, c"{ not json".as_ptr());
            assert_eq!(r.ok, 0);
            let reason = std::ffi::CStr::from_ptr(r.ptr).to_str().unwrap();
            assert!(reason.len() > 10, "reason was {reason:?}");
            photon_string_free(r);
            photon_destroy(h);
        }
    }

    #[test]
    fn an_osc_source_carries_its_address_across() {
        unsafe {
            let h = photon_create(120.0);
            let address = std::ffi::CString::new("/photon/go").unwrap();
            let source = PhotonControlSource {
                kind: source_kind::OSC,
                channel: 0,
                number: 0,
                text: address.as_ptr(),
            };
            assert!(photon_control_arm_action(h, action_kind::CUE_GO, 0, 0));
            let r = photon_control_event(h, source, value_kind::UNIT, 1.0, -1.0);
            assert_eq!(r.kind, routed_kind::LEARNED);
            assert!(photon_control_unbind(h, source));
            assert!(!photon_control_unbind(h, source), "unbinding twice must say no");
            photon_destroy(h);
        }
    }

    #[test]
    fn every_control_entry_point_tolerates_a_null_handle() {
        // The shell calls these from UI code that may run before the engine
        // exists; a crash there is a startup failure with no diagnosis.
        unsafe {
            let null = std::ptr::null_mut::<PhotonCore>();
            assert!(!photon_control_arm_parameter(null, c"a".as_ptr()));
            assert!(!photon_control_arm_action(null, action_kind::CUE_GO, 0, 0));
            assert!(!photon_control_is_learning(null));
            photon_control_disarm(null);
            photon_control_reset_pickup(null);
            assert_eq!(photon_control_binding_count(null), 0);
            assert!(!photon_control_unbind(null, cc_source(1)));
            let r = photon_control_event(null, cc_source(1), value_kind::MIDI7, 1.0, -1.0);
            assert_eq!(r.kind, routed_kind::IGNORED);
            let s = photon_control_map(null);
            assert_eq!(s.ok, 0);
            photon_string_free(s);
        }
    }

    #[test]
    fn a_bound_path_is_readable_without_serialising_the_map() {
        // Pickup needs the target's current value, which means knowing the
        // target. Reading the saved JSON per event would cost a full encode and
        // parse on every message of a fader sweep.
        unsafe {
            let h = photon_create(120.0);
            assert!(photon_control_bound_path(h, cc_source(7)).is_null());

            assert!(photon_control_arm_parameter(h, c"layer.1.opacity".as_ptr()));
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 0.0, -1.0);
            photon_control_event(h, cc_source(7), value_kind::MIDI7, 100.0, -1.0);

            let p = photon_control_bound_path(h, cc_source(7));
            assert!(!p.is_null());
            assert_eq!(std::ffi::CStr::from_ptr(p).to_str().unwrap(), "layer.1.opacity");

            // An action has no position to read back.
            assert!(photon_control_arm_action(h, action_kind::BLACKOUT, 0, 0));
            photon_control_event(h, note_source(36), value_kind::GATE, 1.0, -1.0);
            assert!(photon_control_bound_path(h, note_source(36)).is_null());

            assert!(photon_control_bound_path(std::ptr::null_mut(), cc_source(7)).is_null());
            photon_destroy(h);
        }
    }

    #[test]
    fn an_unknown_source_kind_is_refused_rather_than_guessed() {
        unsafe {
            let h = photon_create(120.0);
            let bogus = PhotonControlSource {
                kind: 99,
                channel: 0,
                number: 0,
                text: std::ptr::null(),
            };
            let r = photon_control_event(h, bogus, value_kind::MIDI7, 64.0, -1.0);
            assert_eq!(r.kind, routed_kind::IGNORED);
            assert!(!photon_control_arm_action(h, 99, 0, 0));
            photon_destroy(h);
        }
    }

    // ── audio reactivity ────────────────────────────────────────────────────

    fn audio_layer(id_: u32, opacity: f32) -> PhotonLayer {
        PhotonLayer { id: id_, blend: 0, opacity, tex_slot: 0, position: 0.0, active: 1 }
    }

    #[test]
    fn an_audio_binding_survives_a_stack_edit() {
        // The failure this prevents: map the bass to a layer, add another
        // layer, and the mapping silently stops working.
        unsafe {
            let h = photon_create(120.0);
            let layers = [audio_layer(1, 1.0)];
            photon_set_layers(h, layers.as_ptr(), 1);

            assert!(photon_bind_audio(h, c"layer.0.opacity".as_ptr(),
                                      20.0, 160.0, 5.0, 120.0, 1.0, false));
            assert_eq!(photon_audio_band_count(h), 1);

            let layers = [audio_layer(1, 1.0), audio_layer(2, 1.0)];
            photon_set_layers(h, layers.as_ptr(), 2);
            assert_eq!(photon_audio_band_count(h), 1, "the binding did not survive");

            // And it still actually drives the parameter.
            assert!(photon_set_audio_band(h, 0, 1.0));
            let f = photon_tick(h, 500_000_000);
            let opacity = (*f.layers).opacity;
            assert!(opacity > 0.1, "a loud band should raise opacity, got {opacity}");
            photon_destroy(h);
        }
    }

    #[test]
    fn the_core_decides_which_bands_the_analyser_computes() {
        // No point running a filter bank nobody reads.
        unsafe {
            let h = photon_create(120.0);
            let layers = [audio_layer(1, 1.0), audio_layer(2, 1.0)];
            photon_set_layers(h, layers.as_ptr(), 2);
            assert_eq!(photon_audio_band_count(h), 0, "nothing bound, nothing to compute");

            photon_bind_audio(h, c"layer.0.opacity".as_ptr(), 20.0, 160.0, 5.0, 120.0, 1.0, false);
            photon_bind_audio(h, c"layer.1.opacity".as_ptr(), 4000.0, 16000.0, 1.0, 60.0, 1.0, false);
            assert_eq!(photon_audio_band_count(h), 2);

            let (mut lo, mut hi) = (0.0f32, 0.0f32);
            assert!(photon_audio_band(h, 0, &mut lo, &mut hi));
            assert!((lo - 20.0).abs() < 0.01 && (hi - 160.0).abs() < 0.01, "{lo}..{hi}");
            assert!(photon_audio_band(h, 1, &mut lo, &mut hi));
            assert!((lo - 4000.0).abs() < 0.01, "{lo}");
            assert!(!photon_audio_band(h, 9, &mut lo, &mut hi), "out of range must say so");
            photon_destroy(h);
        }
    }

    #[test]
    fn binding_the_same_parameter_twice_replaces_rather_than_stacks() {
        // Dragging a band onto a fader twice means "this one", not "both".
        unsafe {
            let h = photon_create(120.0);
            let layers = [audio_layer(1, 1.0)];
            photon_set_layers(h, layers.as_ptr(), 1);
            photon_bind_audio(h, c"layer.0.opacity".as_ptr(), 20.0, 160.0, 5.0, 120.0, 1.0, false);
            photon_bind_audio(h, c"layer.0.opacity".as_ptr(), 4000.0, 16000.0, 5.0, 120.0, 1.0, false);
            assert_eq!(photon_audio_band_count(h), 1);

            let (mut lo, mut hi) = (0.0f32, 0.0f32);
            photon_audio_band(h, 0, &mut lo, &mut hi);
            assert!((lo - 4000.0).abs() < 0.01, "the newer binding should win, got {lo}");

            assert!(photon_unbind_audio(h, c"layer.0.opacity".as_ptr()));
            assert_eq!(photon_audio_band_count(h), 0);
            assert!(!photon_unbind_audio(h, c"layer.0.opacity".as_ptr()));
            photon_destroy(h);
        }
    }

    #[test]
    fn a_nonsense_frequency_range_is_refused() {
        unsafe {
            let h = photon_create(120.0);
            let layers = [audio_layer(1, 1.0)];
            photon_set_layers(h, layers.as_ptr(), 1);
            let p = c"layer.0.opacity".as_ptr();
            assert!(!photon_bind_audio(h, p, 160.0, 20.0, 5.0, 120.0, 1.0, false), "inverted");
            assert!(!photon_bind_audio(h, p, 100.0, 100.0, 5.0, 120.0, 1.0, false), "zero width");
            assert!(!photon_bind_audio(h, p, -10.0, 100.0, 5.0, 120.0, 1.0, false), "negative");
            assert!(!photon_bind_audio(h, p, f32::NAN, 100.0, 5.0, 120.0, 1.0, false), "NaN");
            assert_eq!(photon_audio_band_count(h), 0);
            photon_destroy(h);
        }
    }

    #[test]
    fn a_binding_to_a_missing_layer_is_kept_and_restored() {
        // The layer is gone, not the operator's intent. Re-adding it should
        // bring the mapping back rather than making them redo it.
        unsafe {
            let h = photon_create(120.0);
            let two = [audio_layer(1, 1.0), audio_layer(2, 1.0)];
            photon_set_layers(h, two.as_ptr(), 2);
            photon_bind_audio(h, c"layer.1.opacity".as_ptr(), 20.0, 160.0, 5.0, 120.0, 1.0, false);
            assert_eq!(photon_audio_band_count(h), 1);

            let one = [audio_layer(1, 1.0)];
            photon_set_layers(h, one.as_ptr(), 1);
            assert_eq!(photon_audio_band_count(h), 0, "the parameter is gone");

            photon_set_layers(h, two.as_ptr(), 2);
            assert_eq!(photon_audio_band_count(h), 1, "and the mapping should come back");
            photon_destroy(h);
        }
    }

    #[test]
    fn every_audio_entry_point_tolerates_a_null_handle() {
        unsafe {
            let null = std::ptr::null_mut::<PhotonCore>();
            assert!(!photon_bind_audio(null, c"a".as_ptr(), 20.0, 160.0, 5.0, 120.0, 1.0, false));
            assert!(!photon_unbind_audio(null, c"a".as_ptr()));
            assert_eq!(photon_audio_band_count(null), 0);
            let (mut lo, mut hi) = (0.0f32, 0.0f32);
            assert!(!photon_audio_band(null, 0, &mut lo, &mut hi));
            assert!(!photon_set_audio_band(null, 0, 1.0));
        }
    }
}
