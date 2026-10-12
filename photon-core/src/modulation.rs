//! Parameter modulation — **any source can drive any parameter.**
//!
//! Beat sync, audio reactivity and MIDI mapping are not three features. They
//! are one mechanism with three inputs: a *source* produces a signal, a
//! *binding* maps that signal into a parameter's sweep, and the parameter's
//! ranges decide what the number is allowed to become. Building them
//! separately is how an engine ends up with an LFO that can drive opacity but
//! not playback speed, and a MIDI map that cannot reach either.
//!
//! ## Addressing: paths persist, slots run
//!
//! `layer.3.opacity` is what a human reads and what a `.photon` file stores.
//! [`ParameterRegistry`] resolves it **once, at load**, to a dense
//! [`ParamId`] — an index into contiguous `Vec`s. After that the frame loop
//! only ever does integer indexing: no string compare, no hash, no parse.
//! [`ParamId`] is a runtime handle and is **never persisted**; reload the same
//! document in a different order and the paths still resolve, the integers may
//! differ. The same interning applies to MIDI CCs, OSC addresses and audio
//! bands, which all collapse to [`InputSlot`] indices into one flat table.
//!
//! ## Three ranges, not a depth and an offset
//!
//! Every parameter carries three nested ranges, the model Resolume's shipped
//! presets actually use:
//!
//! | Range | Owner | Meaning |
//! |---|---|---|
//! | `default_range` | the parameter | natural bounds; opacity is 0–1, rotation is -360–360 |
//! | `min_max` | the operator | the usable window, narrowed for this show — *within* `default_range* |
//! | `start_stop` | the modulation | the sweep endpoints — *within* `min_max` |
//!
//! A modulation sweeps between `start_stop`; the result is then clamped to
//! `min_max`. Two ranges do the work one "depth + offset" pair cannot: the
//! operator sets a hard ceiling for the night (`min_max`) *and* an animation
//! that uses part of it (`start_stop`), and narrowing the ceiling mid-set
//! cannot make the animation jump outside it. `start_stop` may be stored
//! reversed (`stop < start`) — that is a descending sweep, not an error, which
//! is why it is a [`Sweep`] and not a [`Bounds`].
//!
//! ## The evaluation pipeline
//!
//! ```text
//! source ─► signal (0..1 or -1..1, clamped to its declared polarity)
//!        ─► invert (polarity-aware)
//!        ─► curve
//!        ─► offset + depth × s          = position in normalised sweep space
//!        ─► Σ over bindings on this param, in binding order
//!        ─► clamp to 0..1
//!        ─► lerp into start_stop
//!        ─► clamp to min_max            = the value the frame uses
//! ```
//!
//! ## Stacking rule: additive, in binding order, clamped once
//!
//! Several bindings may target one parameter. They are **summed in normalised
//! sweep space**, folded left in the order they were bound, and the sum is
//! clamped to `0..1` exactly once, after the fold. Why this and not the
//! alternatives:
//!
//! - **Additive composes; multiplicative deletes.** A slow bar-length LFO for
//!   the bulk movement, a kick-band accent on top, a MIDI fader for live
//!   override is the normal VJ arrangement. Multiplying them means one silent
//!   audio band drags the whole parameter to zero and the operator's LFO
//!   silently stops existing.
//! - **`max`/last-wins discards work.** A binding that is quietly ignored
//!   because another one is louder reads as a broken mapping, and the operator
//!   debugs it mid-show.
//! - **Clamping once is strictly more expressive than clamping per binding.**
//!   `+0.8` and `-0.3` give `0.5`; clamping each first would give `0.8` and
//!   silently drop the negative binding's entire contribution.
//! - **Order is fixed because float addition is not associative.** "Additive"
//!   alone is not deterministic — `(a+b)+c != a+(b+c)` for reachable values.
//!   Bindings live in one `Vec` sorted by [`ParamId`], insertion order kept
//!   within each parameter, so the summation order is a property of the
//!   compiled bank rather than of a hash map's iteration order. The same
//!   document produces the same frame on every machine, every run.
//!
//! ## Allocation
//!
//! [`ModulationEngine::evaluate`] performs **no allocation**. Every buffer it
//! touches (`values`, `signals`, `inputs`, `bindings`) is sized during setup
//! by `register` / `add_source` / `bind`, and `evaluate` only ever indexes and
//! assigns — no `push`, no `resize`, no collection, no iterator that owns.
//! A hard assertion would need a counting global allocator, which needs
//! `unsafe` and this crate forbids it; `evaluation_does_not_reallocate`
//! pins the buffer pointers and capacities across thousands of frames instead,
//! which fails if anything in the loop ever grows.

use std::collections::BTreeMap;

use crate::doc;
use crate::doc::{Curve, LfoShape, ModSource, Rational};
use thiserror::Error;

// ── identities ──────────────────────────────────────────────────────────────

/// A dense runtime handle to a parameter.
///
/// Issued by a [`ParameterRegistry`] and meaningful only against that
/// registry. **Never persisted** — the path is the stable name, this is the
/// index it compiles to.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ParamId(u32);

impl ParamId {
    /// Index into the registry's dense arrays.
    #[must_use]
    pub const fn index(self) -> usize {
        self.0 as usize
    }
}

/// A dense runtime handle to a modulation source.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ModulatorId(u32);

impl ModulatorId {
    /// Index into the engine's modulator array.
    #[must_use]
    pub const fn index(self) -> usize {
        self.0 as usize
    }
}

/// A dense slot in the engine's external-input table.
///
/// One table for every kind of externally supplied value — audio band levels,
/// MIDI CCs, OSC — so the frame loop reads all of them the same way. The
/// network and MIDI threads resolve their address or controller number to a
/// slot once, then write integers-indexed floats.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct InputSlot(u32);

impl InputSlot {
    /// Index into the engine's input table.
    #[must_use]
    pub const fn index(self) -> usize {
        self.0 as usize
    }
}

// ── errors ──────────────────────────────────────────────────────────────────

/// Setup-time modulation errors.
///
/// Every one of these is caught while loading or editing, never in the frame
/// loop — a document that resolves cleanly cannot fail to evaluate.
#[derive(Debug, Clone, PartialEq, Error)]
pub enum ModError {
    /// A non-finite number was supplied. NaN in a range or a depth poisons
    /// every subsequent frame, so it is rejected at the door.
    #[error("{what} must be finite, got {value}")]
    NotFinite {
        /// Which field.
        what: &'static str,
        /// The offending value.
        value: f64,
    },
    /// `lo` is greater than `hi`. Ordered ranges are ordered; a reversed
    /// *sweep* is expressed with [`Sweep`] instead.
    #[error("bounds are inverted: lo {lo} > hi {hi}")]
    Inverted {
        /// Lower bound as given.
        lo: f64,
        /// Upper bound as given.
        hi: f64,
    },
    /// `min_max` escaped `default_range`.
    #[error("minMax {lo}..{hi} is not within defaultRange {outer_lo}..{outer_hi}")]
    OutsideDefaultRange {
        /// Proposed lower bound.
        lo: f64,
        /// Proposed upper bound.
        hi: f64,
        /// The parameter's natural lower bound.
        outer_lo: f64,
        /// The parameter's natural upper bound.
        outer_hi: f64,
    },
    /// `start_stop` escaped `min_max`.
    #[error("startStop {start}..{stop} is not within minMax {lo}..{hi}")]
    OutsideMinMax {
        /// Proposed sweep start.
        start: f64,
        /// Proposed sweep stop.
        stop: f64,
        /// The usable lower bound.
        lo: f64,
        /// The usable upper bound.
        hi: f64,
    },
    /// A [`ParamId`] from a different registry, or a stale one.
    #[error("parameter slot {0} does not exist in this registry")]
    UnknownParam(u32),
    /// A [`ModulatorId`] from a different engine, or a stale one.
    #[error("modulator slot {0} does not exist in this engine")]
    UnknownModulator(u32),
    /// A document binding named a path nothing registered.
    #[error("no parameter registered at path `{0}`")]
    UnknownPath(String),
}

fn finite(what: &'static str, value: f64) -> Result<f64, ModError> {
    if value.is_finite() {
        Ok(value)
    } else {
        Err(ModError::NotFinite { what, value })
    }
}

// ── ranges ──────────────────────────────────────────────────────────────────

/// An ordered, finite, closed interval.
///
/// Used for `default_range` and `min_max`, where "outside" is a safety
/// question and the order carries no meaning.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Bounds {
    lo: f64,
    hi: f64,
}

impl Bounds {
    /// The 0–1 interval: opacity, mix, every normalised parameter.
    pub const UNIT: Self = Self { lo: 0.0, hi: 1.0 };

    /// Creates bounds, rejecting non-finite or inverted input.
    ///
    /// # Errors
    /// [`ModError::NotFinite`] or [`ModError::Inverted`].
    pub fn new(lo: f64, hi: f64) -> Result<Self, ModError> {
        let lo = finite("bounds lo", lo)?;
        let hi = finite("bounds hi", hi)?;
        if lo > hi {
            return Err(ModError::Inverted { lo, hi });
        }
        Ok(Self { lo, hi })
    }

    /// Lower bound.
    #[must_use]
    pub const fn lo(self) -> f64 {
        self.lo
    }

    /// Upper bound.
    #[must_use]
    pub const fn hi(self) -> f64 {
        self.hi
    }

    /// `hi - lo`. Zero for a pinned parameter.
    #[must_use]
    pub const fn span(self) -> f64 {
        self.hi - self.lo
    }

    /// Whether a value lies inside, inclusive.
    #[must_use]
    pub fn contains(self, v: f64) -> bool {
        v >= self.lo && v <= self.hi
    }

    /// Whether another interval lies entirely inside, inclusive.
    #[must_use]
    pub fn contains_bounds(self, other: Self) -> bool {
        other.lo >= self.lo && other.hi <= self.hi
    }

    /// Clamps a value into the interval.
    #[must_use]
    pub fn clamp(self, v: f64) -> f64 {
        v.clamp(self.lo, self.hi)
    }
}

/// Modulation sweep endpoints — **ordered, and deliberately reversible.**
///
/// `start` greater than `stop` is a descending sweep: an LFO rising from 0 to
/// 1 drives the parameter from `start` *down* to `stop`. That is a real
/// setting an operator reaches for (invert a strobe, open an iris backwards)
/// and it is why this is not a [`Bounds`] — ordering here is information, not
/// a mistake to normalise away.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Sweep {
    start: f64,
    stop: f64,
}

impl Sweep {
    /// Creates a sweep. Either ordering is valid.
    ///
    /// # Errors
    /// [`ModError::NotFinite`].
    pub fn new(start: f64, stop: f64) -> Result<Self, ModError> {
        Ok(Self {
            start: finite("sweep start", start)?,
            stop: finite("sweep stop", stop)?,
        })
    }

    /// Value at modulation position 0.
    #[must_use]
    pub const fn start(self) -> f64 {
        self.start
    }

    /// Value at modulation position 1.
    #[must_use]
    pub const fn stop(self) -> f64 {
        self.stop
    }

    /// Lower of the two endpoints.
    #[must_use]
    pub fn lo(self) -> f64 {
        self.start.min(self.stop)
    }

    /// Higher of the two endpoints.
    #[must_use]
    pub fn hi(self) -> f64 {
        self.start.max(self.stop)
    }

    /// Whether the sweep descends.
    #[must_use]
    pub fn is_reversed(self) -> bool {
        self.stop < self.start
    }

    /// Linear interpolation. `t` is expected in 0–1 but is not clamped here —
    /// [`ParamSpec::value_at`] clamps once, after stacking.
    #[must_use]
    pub fn lerp(self, t: f64) -> f64 {
        self.start + (self.stop - self.start) * t
    }
}

/// One parameter's three ranges plus its unmodulated value.
///
/// Invariants, enforced by every constructor and mutator:
/// `min_max ⊆ default_range`, both `start_stop` endpoints ∈ `min_max`, and
/// `base` ∈ `min_max`. Fields are private so none of that can be broken by
/// assignment.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ParamSpec {
    default_range: Bounds,
    min_max: Bounds,
    start_stop: Sweep,
    base: f64,
}

impl ParamSpec {
    /// A parameter spanning `default_range`, with `min_max` wide open and
    /// `start_stop` sweeping the whole thing from `lo` to `hi`.
    #[must_use]
    pub fn new(default_range: Bounds) -> Self {
        Self {
            default_range,
            min_max: default_range,
            start_stop: Sweep {
                start: default_range.lo,
                stop: default_range.hi,
            },
            base: default_range.lo,
        }
    }

    /// A 0–1 parameter. The common case: opacity, mix, most effect controls.
    #[must_use]
    pub fn unit() -> Self {
        Self::new(Bounds::UNIT)
    }

    /// Sets the unmodulated value, clamped into `min_max`.
    #[must_use]
    pub fn with_base(mut self, base: f64) -> Self {
        self.set_base(base);
        self
    }

    /// Narrows the usable window.
    ///
    /// # Errors
    /// [`ModError::OutsideDefaultRange`] if it escapes `default_range`.
    pub fn with_min_max(mut self, min_max: Bounds) -> Result<Self, ModError> {
        self.set_min_max(min_max)?;
        Ok(self)
    }

    /// Sets the modulation sweep.
    ///
    /// # Errors
    /// [`ModError::OutsideMinMax`] if either endpoint escapes `min_max`.
    pub fn with_start_stop(mut self, start_stop: Sweep) -> Result<Self, ModError> {
        self.set_start_stop(start_stop)?;
        Ok(self)
    }

    /// The parameter's natural bounds.
    #[must_use]
    pub const fn default_range(self) -> Bounds {
        self.default_range
    }

    /// The operator's usable window.
    #[must_use]
    pub const fn min_max(self) -> Bounds {
        self.min_max
    }

    /// The modulation sweep endpoints.
    #[must_use]
    pub const fn start_stop(self) -> Sweep {
        self.start_stop
    }

    /// The unmodulated value — where the fader sits.
    #[must_use]
    pub const fn base(self) -> f64 {
        self.base
    }

    /// Sets the unmodulated value, clamped into `min_max`. Non-finite input is
    /// ignored rather than stored, because a NaN here would be read every
    /// frame by every unbound parameter.
    pub fn set_base(&mut self, base: f64) {
        if base.is_finite() {
            self.base = self.min_max.clamp(base);
        }
    }

    /// Narrows or widens the usable window, **pinching `start_stop` to fit**.
    ///
    /// Pinching rather than erroring is deliberate: an operator dragging the
    /// max down mid-show must not get a failure, and the invariant must still
    /// hold afterwards. The sweep keeps its direction; only the endpoints move.
    ///
    /// # Errors
    /// [`ModError::OutsideDefaultRange`] — `default_range` is the parameter's
    /// own definition and is not negotiable.
    pub fn set_min_max(&mut self, min_max: Bounds) -> Result<(), ModError> {
        if !self.default_range.contains_bounds(min_max) {
            return Err(ModError::OutsideDefaultRange {
                lo: min_max.lo,
                hi: min_max.hi,
                outer_lo: self.default_range.lo,
                outer_hi: self.default_range.hi,
            });
        }
        self.min_max = min_max;
        self.start_stop = Sweep {
            start: min_max.clamp(self.start_stop.start),
            stop: min_max.clamp(self.start_stop.stop),
        };
        self.base = min_max.clamp(self.base);
        Ok(())
    }

    /// Sets the modulation sweep.
    ///
    /// # Errors
    /// [`ModError::OutsideMinMax`] if either endpoint escapes `min_max`. This
    /// one *does* error: a sweep outside the usable window is an editing
    /// mistake, and silently clamping it would hide a preset that no longer
    /// does what its author wrote.
    pub fn set_start_stop(&mut self, start_stop: Sweep) -> Result<(), ModError> {
        if !self.min_max.contains(start_stop.start) || !self.min_max.contains(start_stop.stop) {
            return Err(ModError::OutsideMinMax {
                start: start_stop.start,
                stop: start_stop.stop,
                lo: self.min_max.lo,
                hi: self.min_max.hi,
            });
        }
        self.start_stop = start_stop;
        Ok(())
    }

    /// The value for an unmodulated parameter.
    #[must_use]
    pub fn base_value(self) -> f64 {
        self.min_max.clamp(self.base)
    }

    /// Maps a stacked modulation position to a final value.
    ///
    /// `position` is clamped to 0–1 (a sweep sweeps *between* its endpoints,
    /// it does not extrapolate past them), lerped across `start_stop`, then
    /// clamped to `min_max`.
    ///
    /// The second clamp is not redundant with the nesting invariant.
    /// `start + (stop - start) * t` is **not** guaranteed to stay between its
    /// own endpoints in binary floating point — for real values it overshoots
    /// by an ulp (see `a_value_never_escapes_min_max_even_when_lerp_overshoots`)
    /// — and `min_max` is the hard guarantee everything downstream relies on:
    /// a shader uniform, an opacity, a projector brightness ceiling the
    /// operator set for a reason. It is also what holds if a future editor ever
    /// narrows `min_max` without re-validating the sweep.
    #[must_use]
    pub fn value_at(self, position: f64) -> f64 {
        let t = if position.is_nan() {
            0.0
        } else {
            position.clamp(0.0, 1.0)
        };
        self.min_max.clamp(self.start_stop.lerp(t))
    }
}

// ── parameter registry ──────────────────────────────────────────────────────

/// Readable parameter paths in, dense slots out.
///
/// The only place in the engine that knows a parameter has a name. Resolution
/// happens at load and on edit; the frame loop indexes integers.
#[derive(Debug, Clone, Default)]
pub struct ParameterRegistry {
    /// Slot → path. Dense, index is the [`ParamId`].
    paths: Vec<String>,
    /// Slot → ranges. Dense, parallel to `paths`.
    specs: Vec<ParamSpec>,
    /// Path → slot. Ordered rather than hashed so iteration and diagnostics
    /// are reproducible run to run; it is only touched at setup.
    index: BTreeMap<String, ParamId>,
}

impl ParameterRegistry {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers a path, or updates the spec of one already registered.
    ///
    /// Idempotent per path: re-registering returns the same [`ParamId`] and
    /// replaces the spec, which is what a document reload needs — the slot
    /// stays valid for anything already bound to it.
    pub fn register(&mut self, path: &str, spec: ParamSpec) -> ParamId {
        if let Some(&id) = self.index.get(path) {
            self.specs[id.index()] = spec;
            return id;
        }
        let id = ParamId(u32::try_from(self.paths.len()).expect("parameter count exceeds u32"));
        self.paths.push(path.to_owned());
        self.specs.push(spec);
        self.index.insert(path.to_owned(), id);
        id
    }

    /// Resolves a readable path to its slot. `None` if nothing registered it.
    #[must_use]
    pub fn resolve(&self, path: &str) -> Option<ParamId> {
        self.index.get(path).copied()
    }

    /// Reverse lookup: the readable path for a slot. For UI, OSC replies and
    /// error messages — never the frame loop.
    #[must_use]
    pub fn path(&self, id: ParamId) -> Option<&str> {
        self.paths.get(id.index()).map(String::as_str)
    }

    /// The ranges for a slot.
    #[must_use]
    pub fn spec(&self, id: ParamId) -> Option<&ParamSpec> {
        self.specs.get(id.index())
    }

    /// Mutable ranges for a slot, for live editing.
    pub fn spec_mut(&mut self, id: ParamId) -> Option<&mut ParamSpec> {
        self.specs.get_mut(id.index())
    }

    /// Number of registered parameters.
    #[must_use]
    pub fn len(&self) -> usize {
        self.paths.len()
    }

    /// Whether nothing is registered.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.paths.is_empty()
    }

    /// Every slot with its path, in slot order.
    pub fn iter(&self) -> impl Iterator<Item = (ParamId, &str)> {
        self.paths
            .iter()
            .enumerate()
            .map(|(i, p)| (ParamId(i as u32), p.as_str()))
    }

    fn check(&self, id: ParamId) -> Result<(), ModError> {
        if id.index() < self.specs.len() {
            Ok(())
        } else {
            Err(ModError::UnknownParam(id.0))
        }
    }
}

// ── sources ─────────────────────────────────────────────────────────────────

/// The range a source's signal occupies.
///
/// Carried explicitly because it changes what `invert` means and what a
/// full-sweep binding looks like — guessing it from an observed value is how
/// an LFO ends up only using the top half of a parameter.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Polarity {
    /// 0 to 1. Envelopes, audio levels, faders, OSC.
    Unipolar,
    /// -1 to 1. Oscillators, which swing around a centre.
    Bipolar,
}

impl Polarity {
    /// Clamps a raw signal into this polarity's range, mapping NaN to zero.
    ///
    /// Both halves matter. The clamp stops a rogue OSC value of `1000.0` from
    /// saturating an additive stack and silently hiding every other binding on
    /// that parameter. The NaN guard stops one bad packet from pinning a
    /// parameter to NaN for the rest of the show — NaN survives `clamp`,
    /// propagates through every arithmetic step, and reaches the compositor.
    #[must_use]
    pub fn clamp_signal(self, v: f64) -> f64 {
        if v.is_nan() {
            return 0.0;
        }
        match self {
            Self::Unipolar => v.clamp(0.0, 1.0),
            Self::Bipolar => v.clamp(-1.0, 1.0),
        }
    }
}

/// Envelope stage.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EnvStage {
    Idle,
    Attack,
    Release,
}

/// A compiled modulation source.
///
/// Private: a source is created from a [`ModSource`] (or as a manual
/// constant), and from then on is addressed by [`ModulatorId`].
#[derive(Debug, Clone)]
enum Modulator {
    /// Oscillator locked to musical time. **Stateless** — phase is derived
    /// from the absolute beat position every frame rather than accumulated, so
    /// a tempo change, a loop jump or a dropped frame re-locks to the beat
    /// instantly instead of drifting away from it forever.
    BeatLfo {
        shape: LfoShape,
        period_beats: f64,
        phase: f64,
        seed: u64,
    },
    /// One-shot attack/release, armed by [`ModulationEngine::trigger`].
    Envelope {
        attack_s: f64,
        release_s: f64,
        stage: EnvStage,
        level: f64,
    },
    /// Audio band level fed in by the shell's analyser, smoothed here so the
    /// attack/release shape is identical whatever the analyser's block size.
    Follower {
        slot: InputSlot,
        attack_s: f64,
        release_s: f64,
        level: f64,
    },
    /// Externally written control value, used as-is: MIDI CC and OSC.
    Direct { slot: InputSlot },
    /// A constant the operator sets by hand. The "source" for a parameter
    /// someone wants to park and still route through curves and stacking.
    Manual { value: f64 },
}

impl Modulator {
    const fn polarity(&self) -> Polarity {
        match self {
            Self::BeatLfo { .. } => Polarity::Bipolar,
            _ => Polarity::Unipolar,
        }
    }

    /// Advances state by one frame and returns the raw signal.
    fn advance(&mut self, time: FrameTime, inputs: &[f64]) -> f64 {
        match self {
            Self::BeatLfo {
                shape,
                period_beats,
                phase,
                seed,
            } => {
                let (p, cycles) = beat_phase(time.beat, *period_beats, *phase);
                lfo(*shape, p, cycles, *seed)
            }
            Self::Envelope {
                attack_s,
                release_s,
                stage,
                level,
            } => {
                // A frame delta the shell got wrong must not be able to kill
                // the envelope for the rest of the show. [`one_pole`] already
                // treats a non-finite or non-positive `dt` as a degenerate
                // frame; the linear ramp needs the same rule, because `level`
                // here is *accumulated* rather than recomputed and so a single
                // bad frame is permanent:
                //
                // - `dt = NaN` makes `level` NaN, NaN fails both `>= 1.0` and
                //   `<= 0.0`, so the stage machine never advances again and
                //   even `trigger` cannot rescue it. The polarity clamp hides
                //   it (NaN → 0), which makes it a *silently* dead envelope.
                // - `dt < 0` (a shell that subtracted two timestamps the wrong
                //   way round, or a clock that stepped back) drives `level`
                //   thousands of units out of range and the envelope is mute
                //   for minutes of real time while it crawls back.
                //
                // Freezing for the bad frame is the conservative answer: the
                // next good frame resumes exactly where the ramp was.
                let dt = if time.dt_seconds.is_finite() && time.dt_seconds > 0.0 {
                    time.dt_seconds
                } else {
                    0.0
                };
                match stage {
                    EnvStage::Idle => *level = 0.0,
                    EnvStage::Attack => {
                        *level = if *attack_s > 0.0 {
                            *level + dt / *attack_s
                        } else {
                            1.0
                        };
                        if *level >= 1.0 {
                            *level = 1.0;
                            *stage = EnvStage::Release;
                        }
                    }
                    EnvStage::Release => {
                        *level = if *release_s > 0.0 {
                            *level - dt / *release_s
                        } else {
                            0.0
                        };
                        if *level <= 0.0 {
                            *level = 0.0;
                            *stage = EnvStage::Idle;
                        }
                    }
                }
                *level
            }
            Self::Follower {
                slot,
                attack_s,
                release_s,
                level,
            } => {
                let raw = Polarity::Unipolar.clamp_signal(inputs[slot.index()]);
                let tau = if raw > *level { *attack_s } else { *release_s };
                *level += (raw - *level) * one_pole(tau, time.dt_seconds);
                *level
            }
            Self::Direct { slot } => inputs[slot.index()],
            Self::Manual { value } => *value,
        }
    }
}

/// One-pole smoothing coefficient for a time constant and a frame delta.
///
/// `1 - e^(-dt/tau)`, so the shape is frame-rate independent: the same
/// attack sounds the same at 60 and at 144 fps.
///
/// The two degenerate inputs mean **opposite** things and are answered
/// separately, which is the bug this once had: a bad `dt` and a bad `tau` both
/// returned `1.0`, so a frame with `dt = 0` collapsed every audio follower
/// straight onto the raw band level and discarded the attack and release the
/// operator set. `dt = 0` is not exotic — a paused transport, two evaluations
/// inside one frame, or the very first frame all produce it, and `dt < 0` is
/// one subtraction the wrong way round. It is silent, because the result is a
/// perfectly plausible number.
///
/// - **Bad frame delta** (zero, negative, non-finite): no time passed, so the
///   filter must not move. `0.0`. This is the rule [`Modulator::Envelope`]
///   already states for itself — freeze, and let the next good frame resume
///   exactly where the ramp was.
/// - **Bad time constant** (zero, negative, non-finite): no smoothing was
///   asked for. `1.0` — instant, which is what a 0 ms attack means.
fn one_pole(tau_s: f64, dt_s: f64) -> f64 {
    if !dt_s.is_finite() || dt_s <= 0.0 {
        return 0.0;
    }
    if !tau_s.is_finite() || tau_s <= 0.0 {
        return 1.0;
    }
    1.0 - (-dt_s / tau_s).exp()
}

/// Phase within the LFO cycle, plus the unwrapped cycle count for noise.
///
/// Returns `(phase ∈ [0,1), cycles)`. For the common case — a whole number of
/// beats per cycle, which is every musically useful setting — the modulo is
/// done in **exact integer arithmetic** on the [`Rational`] beat position, so
/// the downbeat is bit-exact at beat 0 and at beat 4,000,000 alike. That is
/// the same reason [`Rational`] exists at all: `fract()` of an accumulated
/// float is not.
fn beat_phase(beat: Rational, period_beats: f64, offset: f64) -> (f64, f64) {
    // NaN is caught by `is_finite`, so the second test never sees one.
    if !period_beats.is_finite() || period_beats <= 0.0 {
        // A zero or nonsensical period freezes the oscillator at its offset
        // rather than dividing by zero and painting NaN.
        let p = offset.rem_euclid(1.0);
        return (p, p);
    }

    let exact = if period_beats.fract() == 0.0 && period_beats <= 1.0e15 {
        let whole = period_beats as i64;
        beat.den()
            .checked_mul(whole)
            .filter(|m| *m > 0)
            .map(|m| beat.num().rem_euclid(m) as f64 / m as f64)
    } else {
        None
    };

    let cycles = beat.to_f64() / period_beats + offset;
    let phase = match exact {
        Some(p) => (p + offset).rem_euclid(1.0),
        None => cycles.rem_euclid(1.0),
    };
    (phase, cycles)
}

/// Evaluates a waveform at a phase, bipolar.
///
/// Conventions, all chosen so the downbeat is the interesting instant:
/// saw and triangle reset to `-1` on the beat, square is *on* (`+1`) for the
/// first half, sine crosses zero rising, noise lands on a fresh value.
fn lfo(shape: LfoShape, phase: f64, cycles: f64, seed: u64) -> f64 {
    match shape {
        LfoShape::Sine => (phase * std::f64::consts::TAU).sin(),
        LfoShape::Saw => 2.0 * phase - 1.0,
        LfoShape::Square => {
            if phase < 0.5 {
                1.0
            } else {
                -1.0
            }
        }
        LfoShape::Triangle => 1.0 - 4.0 * (phase - 0.5).abs(),
        LfoShape::Noise => value_noise(cycles, seed) * 2.0 - 1.0,
    }
}

/// Smooth value noise over the cycle index, in 0–1.
///
/// Deterministic from `(cycle, seed)` with no state and no allocation, so a
/// saved show replays identically and two noise LFOs do not move in lockstep.
/// New random value on each cycle boundary, smoothstepped between — a
/// sample-and-hold would be a square wave with extra steps.
fn value_noise(cycles: f64, seed: u64) -> f64 {
    let i = cycles.floor();
    let f = cycles - i;
    let i = i as i64;
    let a = unit_hash(seed, i);
    let b = unit_hash(seed, i.wrapping_add(1));
    let t = f * f * (3.0 - 2.0 * f);
    a + (b - a) * t
}

/// splitmix64 finaliser — a cheap, well-distributed integer hash.
const fn mix(mut z: u64) -> u64 {
    z = z.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

/// Hash to a 0–1 double.
fn unit_hash(seed: u64, i: i64) -> f64 {
    let h = mix(seed ^ mix(i as u64));
    // Top 53 bits give a uniform value in [0,1) with no rounding bias.
    (h >> 11) as f64 / (1u64 << 53) as f64
}

// ── bindings ────────────────────────────────────────────────────────────────

/// One source driving one parameter.
///
/// The runtime form of [`crate::doc::Binding`]: the path has already become a
/// [`ParamId`] and the inline source has already become a [`ModulatorId`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Binding {
    /// Parameter slot being driven.
    pub param: ParamId,
    /// Source slot driving it.
    pub modulator: ModulatorId,
    /// Scale applied to the shaped signal, in normalised sweep space.
    pub depth: f64,
    /// Added after scaling — the centre of the movement.
    pub offset: f64,
    /// Response shape.
    pub curve: Curve,
    /// Invert the source value, before the curve.
    pub invert: bool,
}

impl Binding {
    /// A binding that sweeps the parameter's whole `start_stop` range.
    ///
    /// The right defaults differ by polarity, which is the entire reason
    /// [`Polarity`] is carried around: a unipolar source wants
    /// `offset 0, depth 1`, a bipolar one wants `offset 0.5, depth 0.5` or it
    /// only ever reaches the top half.
    #[must_use]
    pub fn full_sweep(param: ParamId, modulator: ModulatorId, polarity: Polarity) -> Self {
        let (depth, offset) = match polarity {
            Polarity::Unipolar => (1.0, 0.0),
            Polarity::Bipolar => (0.5, 0.5),
        };
        Self {
            param,
            modulator,
            depth,
            offset,
            curve: Curve::Linear,
            invert: false,
        }
    }
}

/// A binding with its source's polarity folded in, so the frame loop does not
/// chase a second index to find it.
#[derive(Debug, Clone, Copy)]
struct Compiled {
    param: ParamId,
    modulator: ModulatorId,
    depth: f64,
    offset: f64,
    curve: Curve,
    invert: bool,
    polarity: Polarity,
}

impl Compiled {
    /// Signal → position in normalised sweep space. Not clamped: the stack is
    /// clamped once, after summing.
    fn position(&self, raw: f64) -> f64 {
        let s = self.polarity.clamp_signal(raw);
        // Invert first, curve second. The curve describes how the *resulting*
        // motion accelerates; shaping before inverting would mirror the curve
        // too, so ticking "invert" would quietly change the feel of the easing
        // as well as its direction.
        let s = if self.invert {
            match self.polarity {
                Polarity::Unipolar => 1.0 - s,
                // Negating a unipolar signal would push it outside its own
                // declared range and change what depth/offset mean; mirroring
                // a bipolar one around its centre is exactly right.
                Polarity::Bipolar => -s,
            }
        } else {
            s
        };
        self.offset + self.depth * apply_curve(self.curve, s)
    }
}

/// Applies a response curve, preserving sign.
///
/// All four agree at the endpoints (`0→0`, `1→1`, `-1→-1`) and differ in
/// between; shaping the magnitude and restoring the sign keeps a bipolar
/// oscillator symmetric instead of squashing one half of its swing.
fn apply_curve(curve: Curve, x: f64) -> f64 {
    let m = x.abs().min(1.0);
    let shaped = match curve {
        Curve::Linear => m,
        // Squared and square-root are exact inverses of each other, so an
        // "exponential" send and a "logarithmic" one cancel — which is what an
        // operator expects when they A/B the two.
        Curve::Exponential => m * m,
        Curve::Logarithmic => m.sqrt(),
        Curve::SCurve => m * m * (3.0 - 2.0 * m),
    };
    if x < 0.0 {
        -shaped
    } else {
        shaped
    }
}

// ── engine ──────────────────────────────────────────────────────────────────

/// Time handed to the engine once per frame.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FrameTime {
    /// Exact musical position in beats, from the clock. Rational, never
    /// accumulated as a float.
    pub beat: Rational,
    /// Wall-clock seconds since the previous evaluation.
    ///
    /// Envelopes and audio followers are specified in milliseconds and run on
    /// **real** time, not musical time — a 50 ms kick attack is a property of
    /// the kick, and stretching it when the DJ pitches the track down would be
    /// wrong. Only the LFOs are musical.
    pub dt_seconds: f64,
}

impl FrameTime {
    /// Convenience for tests and for a fixed-cadence shell.
    #[must_use]
    pub fn new(beat: Rational, dt_seconds: f64) -> Self {
        Self { beat, dt_seconds }
    }
}

/// Owns the parameter registry, the compiled sources, the bindings and the
/// per-frame scratch buffers.
///
/// Holding the registry rather than taking it per call is deliberate: a
/// [`ParamId`] is only meaningful against one registry, and letting the two
/// drift would mean bindings silently driving the wrong parameter — the kind
/// of bug that only shows up on the one document that reordered its layers.
#[derive(Debug, Clone, Default)]
pub struct ModulationEngine {
    params: ParameterRegistry,
    modulators: Vec<Modulator>,
    /// Sorted by `param`, insertion order preserved within each parameter.
    /// That ordering **is** the stacking rule; see the module docs.
    bindings: Vec<Compiled>,

    /// Scratch, len == `modulators.len()`.
    signals: Vec<f64>,
    /// Scratch, len == `params.len()`.
    values: Vec<f64>,
    /// External input table, written by the shell, read by `Direct`/`Follower`.
    inputs: Vec<f64>,

    midi: BTreeMap<(u8, u8), InputSlot>,
    osc: BTreeMap<String, InputSlot>,
    /// `(low_hz, high_hz, slot)` — kept as a list because the analyser needs to
    /// enumerate the bands it has to compute, not just look them up.
    bands: Vec<(f64, f64, InputSlot)>,
}

impl ModulationEngine {
    /// An empty engine.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// An engine over an already-populated registry, as built while walking a
    /// loaded document.
    #[must_use]
    pub fn with_params(params: ParameterRegistry) -> Self {
        // Seeded from the specs rather than zeroed, so reading a value before
        // the first frame gives the fader position rather than black.
        let values = params.specs.iter().map(|s| s.base_value()).collect();
        Self {
            params,
            values,
            ..Self::default()
        }
    }

    // ── setup: parameters ───────────────────────────────────────────────────

    /// Registers a parameter path and sizes the value buffer to match.
    ///
    /// Re-registering an existing path replaces its spec *and* its pre-frame
    /// value. Both halves matter: leaving the old value behind made
    /// [`Self::value`] report the previous fader position until the next
    /// [`Self::evaluate`], which is exactly the window the UI draws in after a
    /// document reload — the one case [`ParameterRegistry::register`] is
    /// idempotent for.
    pub fn register(&mut self, path: &str, spec: ParamSpec) -> ParamId {
        let id = self.params.register(path, spec);
        if id.index() == self.values.len() {
            self.values.push(spec.base_value());
        } else {
            self.values[id.index()] = spec.base_value();
        }
        id
    }

    /// The registry, for path lookup and UI.
    #[must_use]
    pub fn params(&self) -> &ParameterRegistry {
        &self.params
    }

    /// Edits a parameter's ranges in place.
    pub fn spec_mut(&mut self, param: ParamId) -> Option<&mut ParamSpec> {
        self.params.spec_mut(param)
    }

    // ── setup: sources ──────────────────────────────────────────────────────

    /// Compiles a document source into a dense slot, interning any external
    /// input it needs (MIDI CC, OSC address, audio band) at the same time.
    ///
    /// Sources are **not** deduplicated: two document bindings that both carry
    /// a 4-beat sine get two slots, because that is what the document says and
    /// because they can be re-pointed independently later. Identical LFO specs
    /// produce identical signals anyway, so the only cost is a few bytes.
    pub fn add_source(&mut self, source: &ModSource) -> ModulatorId {
        let m = match source {
            ModSource::BeatLfo {
                shape,
                beats,
                phase,
            } => Modulator::BeatLfo {
                shape: *shape,
                period_beats: *beats,
                // A non-finite phase offset from a hand-edited document would
                // make `beat_phase` return NaN every frame, which the polarity
                // clamp turns into a permanently silent LFO with no
                // diagnostic. `beats` is already handled inside `beat_phase`
                // (a nonsensical period freezes rather than divides by zero);
                // this is the same containment for the other field, and it
                // matches what `add_manual` does with a non-finite constant.
                phase: if phase.is_finite() { *phase } else { 0.0 },
                // Seeded from the slot index so a saved show replays exactly.
                // Inserting a source ahead of this one reseeds it — noise is
                // the one source nobody recalls by eye.
                seed: mix(self.modulators.len() as u64),
            },
            ModSource::Envelope {
                attack_ms,
                release_ms,
            } => Modulator::Envelope {
                attack_s: ms(*attack_ms),
                release_s: ms(*release_ms),
                stage: EnvStage::Idle,
                level: 0.0,
            },
            ModSource::AudioBand {
                low_hz,
                high_hz,
                attack_ms,
                release_ms,
            } => {
                let slot = self.intern_band(*low_hz, *high_hz);
                Modulator::Follower {
                    slot,
                    attack_s: ms(*attack_ms),
                    release_s: ms(*release_ms),
                    level: 0.0,
                }
            }
            ModSource::MidiCc { channel, cc } => Modulator::Direct {
                slot: self.intern_midi(*channel, *cc),
            },
            ModSource::Osc { address } => Modulator::Direct {
                slot: self.intern_osc(address),
            },
        };
        self.push_modulator(m)
    }

    /// Adds a hand-set constant source.
    ///
    /// [`ModSource`] has no such variant because a constant is not worth
    /// persisting as a modulation *source* — but at runtime it is one, and
    /// having it here means a parked fader goes through the same curve,
    /// inversion and stacking path as everything else instead of being a
    /// special case the rest of the engine has to know about.
    pub fn add_manual(&mut self, value: f64) -> ModulatorId {
        self.push_modulator(Modulator::Manual {
            value: if value.is_finite() { value } else { 0.0 },
        })
    }

    fn push_modulator(&mut self, m: Modulator) -> ModulatorId {
        let id = ModulatorId(u32::try_from(self.modulators.len()).expect("modulator count"));
        self.modulators.push(m);
        self.signals.push(0.0);
        id
    }

    /// The polarity of a compiled source.
    #[must_use]
    pub fn polarity(&self, modulator: ModulatorId) -> Option<Polarity> {
        self.modulators.get(modulator.index()).map(Modulator::polarity)
    }

    /// Sets a manual source's value. No-op for any other kind of source.
    pub fn set_manual(&mut self, modulator: ModulatorId, value: f64) {
        if let Some(Modulator::Manual { value: v }) = self.modulators.get_mut(modulator.index()) {
            if value.is_finite() {
                *v = value;
            }
        }
    }

    /// Fires an envelope. No-op for any other kind of source.
    ///
    /// Retriggering mid-flight ramps up from wherever the envelope currently
    /// is rather than snapping to zero, so a fast re-launch does not click.
    pub fn trigger(&mut self, modulator: ModulatorId) {
        if let Some(Modulator::Envelope { stage, .. }) = self.modulators.get_mut(modulator.index())
        {
            *stage = EnvStage::Attack;
        }
    }

    // ── setup: external inputs ──────────────────────────────────────────────

    fn intern_input(&mut self) -> InputSlot {
        let slot = InputSlot(u32::try_from(self.inputs.len()).expect("input count"));
        self.inputs.push(0.0);
        slot
    }

    fn intern_midi(&mut self, channel: u8, cc: u8) -> InputSlot {
        if let Some(&slot) = self.midi.get(&(channel, cc)) {
            return slot;
        }
        let slot = self.intern_input();
        self.midi.insert((channel, cc), slot);
        slot
    }

    fn intern_osc(&mut self, address: &str) -> InputSlot {
        if let Some(&slot) = self.osc.get(address) {
            return slot;
        }
        let slot = self.intern_input();
        self.osc.insert(address.to_owned(), slot);
        slot
    }

    fn intern_band(&mut self, low_hz: f64, high_hz: f64) -> InputSlot {
        // Bit-exact matching: two bands share an analyser slot only if they
        // were specified identically. Fuzzy matching would quietly merge
        // 20–120 Hz with 20–121 Hz and lose one of them.
        if let Some(&(_, _, slot)) = self
            .bands
            .iter()
            .find(|(l, h, _)| l.to_bits() == low_hz.to_bits() && h.to_bits() == high_hz.to_bits())
        {
            return slot;
        }
        let slot = self.intern_input();
        self.bands.push((low_hz, high_hz, slot));
        slot
    }

    /// The slot a MIDI controller writes to, if anything mapped it.
    #[must_use]
    pub fn midi_slot(&self, channel: u8, cc: u8) -> Option<InputSlot> {
        self.midi.get(&(channel, cc)).copied()
    }

    /// The slot an OSC address writes to, if anything mapped it.
    #[must_use]
    pub fn osc_slot(&self, address: &str) -> Option<InputSlot> {
        self.osc.get(address).copied()
    }

    /// The slot an audio band writes to, if anything mapped it.
    #[must_use]
    pub fn band_slot(&self, low_hz: f64, high_hz: f64) -> Option<InputSlot> {
        self.bands
            .iter()
            .find(|(l, h, _)| l.to_bits() == low_hz.to_bits() && h.to_bits() == high_hz.to_bits())
            .map(|&(_, _, slot)| slot)
    }

    /// Every audio band some binding asked for, as `(low_hz, high_hz, slot)`.
    ///
    /// The analyser computes exactly these and nothing else — no point running
    /// a filter bank nobody reads.
    pub fn audio_bands(&self) -> impl Iterator<Item = (f64, f64, InputSlot)> + '_ {
        self.bands.iter().copied()
    }

    /// Writes an external input. Expected in 0–1; out-of-range values saturate
    /// rather than dominate (see [`Polarity::clamp_signal`]).
    pub fn set_input(&mut self, slot: InputSlot, value: f64) {
        if let Some(v) = self.inputs.get_mut(slot.index()) {
            *v = value;
        }
    }

    /// Writes a MIDI CC by controller number, normalising 0–127 to 0–1.
    ///
    /// Returns whether anything is mapped to it. Called from the MIDI thread,
    /// not the frame loop; the map lookup is on control-rate data.
    pub fn set_midi_cc(&mut self, channel: u8, cc: u8, value: u8) -> bool {
        match self.midi_slot(channel, cc) {
            Some(slot) => {
                self.set_input(slot, f64::from(value) / 127.0);
                true
            }
            None => false,
        }
    }

    /// Writes an OSC value by address. Returns whether anything is mapped.
    ///
    /// Called from the network thread. The string lookup happens here, once
    /// per message — never in [`Self::evaluate`].
    pub fn set_osc(&mut self, address: &str, value: f64) -> bool {
        match self.osc_slot(address) {
            Some(slot) => {
                self.set_input(slot, value);
                true
            }
            None => false,
        }
    }

    // ── setup: bindings ─────────────────────────────────────────────────────

    /// Adds a binding.
    ///
    /// Inserted at the end of its parameter's group, which keeps `bindings`
    /// sorted by [`ParamId`] *and* preserves bind order within a parameter —
    /// the two properties the stacking rule is built on.
    ///
    /// # Errors
    /// [`ModError::UnknownParam`], [`ModError::UnknownModulator`] or
    /// [`ModError::NotFinite`].
    pub fn bind(&mut self, binding: Binding) -> Result<(), ModError> {
        self.params.check(binding.param)?;
        let polarity = self
            .polarity(binding.modulator)
            .ok_or(ModError::UnknownModulator(binding.modulator.0))?;
        finite("binding depth", binding.depth)?;
        finite("binding offset", binding.offset)?;

        let compiled = Compiled {
            param: binding.param,
            modulator: binding.modulator,
            depth: binding.depth,
            offset: binding.offset,
            curve: binding.curve,
            invert: binding.invert,
            polarity,
        };
        let at = self
            .bindings
            .partition_point(|b| b.param <= compiled.param);
        self.bindings.insert(at, compiled);
        Ok(())
    }

    /// Binds a source to drive a parameter across its whole sweep.
    ///
    /// # Errors
    /// As [`Self::bind`].
    pub fn bind_full_sweep(
        &mut self,
        param: ParamId,
        modulator: ModulatorId,
    ) -> Result<(), ModError> {
        let polarity = self
            .polarity(modulator)
            .ok_or(ModError::UnknownModulator(modulator.0))?;
        self.bind(Binding::full_sweep(param, modulator, polarity))
    }

    /// Loads a persisted binding: resolves its path, compiles its source,
    /// binds it. **This is the only place a parameter string is ever read.**
    ///
    /// Returns the slot the source landed in, so the caller can trigger it
    /// (envelopes) or re-point it later.
    ///
    /// # Errors
    /// [`ModError::UnknownPath`] if the document names a parameter this build
    /// does not have — a loud failure, because silently dropping the binding
    /// is how a show loses a mapping nobody notices until it is on stage.
    pub fn bind_document(&mut self, binding: &doc::Binding) -> Result<ModulatorId, ModError> {
        let param = self
            .params
            .resolve(&binding.target)
            .ok_or_else(|| ModError::UnknownPath(binding.target.clone()))?;
        // Validate before allocating a modulator slot, so a rejected binding
        // does not leave an orphan source behind.
        finite("binding depth", binding.depth)?;
        finite("binding offset", binding.offset)?;

        let modulator = self.add_source(&binding.source);
        self.bind(Binding {
            param,
            modulator,
            depth: binding.depth,
            offset: binding.offset,
            curve: binding.curve,
            invert: binding.invert,
        })?;
        Ok(modulator)
    }

    /// Number of bindings.
    #[must_use]
    pub fn binding_count(&self) -> usize {
        self.bindings.len()
    }

    // ── the frame loop ──────────────────────────────────────────────────────

    /// Produces final values for every parameter.
    ///
    /// Allocation-free: three passes over buffers that were sized at setup,
    /// writing in place. No `push`, no `resize`, no temporary collection, no
    /// string touched.
    pub fn evaluate(&mut self, time: FrameTime) {
        // Split the borrow so the three passes can read and write disjoint
        // fields without cloning anything.
        let Self {
            params,
            modulators,
            bindings,
            signals,
            values,
            inputs,
            ..
        } = self;

        debug_assert_eq!(values.len(), params.specs.len());
        debug_assert_eq!(signals.len(), modulators.len());
        // Pass 3 walks `bindings` as contiguous runs of one parameter. That is
        // only correct while the vec stays sorted by `ParamId`, an invariant
        // established in exactly one place (`bind`) and relied on silently
        // here: unsorted, the loop sums the wrong bindings into the wrong
        // parameter and nothing panics or fails a test. The first `unbind`,
        // `remove_source` or re-point to land is what breaks it.
        debug_assert!(bindings.is_sorted_by_key(|b| b.param));

        // 1. Every source advances once per frame, whether or not it is bound.
        //    State (envelopes, followers) must keep running so a binding added
        //    mid-show picks up a settled value instead of a cold one.
        for (slot, m) in modulators.iter_mut().enumerate() {
            signals[slot] = m.advance(time, inputs);
        }

        // 2. Seed every parameter with its unmodulated value. Unbinding a
        //    parameter therefore reverts it on the next frame, with no
        //    bookkeeping about which ones used to be driven.
        for (v, spec) in values.iter_mut().zip(params.specs.iter()) {
            *v = spec.base_value();
        }

        // 3. One pass over bindings, which are grouped by parameter, summing
        //    each group in bind order and resolving once at the group's end.
        //    The base value is *replaced*, not added to: `offset` is already
        //    how a binding sets its centre, and seeding from the fader would
        //    make the same binding mean different things depending on where an
        //    unrelated control happened to be left.
        let mut i = 0;
        while i < bindings.len() {
            let param = bindings[i].param;
            let mut acc = 0.0;
            while i < bindings.len() && bindings[i].param == param {
                let b = &bindings[i];
                acc += b.position(signals[b.modulator.index()]);
                i += 1;
            }
            values[param.index()] = params.specs[param.index()].value_at(acc);
        }
    }

    /// The value of one parameter from the last evaluation.
    #[must_use]
    pub fn value(&self, param: ParamId) -> Option<f64> {
        self.values.get(param.index()).copied()
    }

    /// Every parameter value from the last evaluation, indexed by slot.
    #[must_use]
    pub fn values(&self) -> &[f64] {
        &self.values
    }

    /// The raw signal of one source from the last evaluation — for meters.
    #[must_use]
    pub fn signal(&self, modulator: ModulatorId) -> Option<f64> {
        self.signals.get(modulator.index()).copied()
    }
}

/// Milliseconds to seconds, treating nonsense as instant.
fn ms(v: f64) -> f64 {
    if v.is_finite() && v > 0.0 {
        v / 1000.0
    } else {
        0.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn beat(n: i64, d: i64) -> Rational {
        Rational::new(n, d)
    }

    fn at(n: i64, d: i64) -> FrameTime {
        FrameTime::new(beat(n, d), 1.0 / 60.0)
    }

    fn unit_engine(path: &str) -> (ModulationEngine, ParamId) {
        let mut e = ModulationEngine::new();
        let p = e.register(path, ParamSpec::unit());
        (e, p)
    }

    // ── registry ────────────────────────────────────────────────────────────

    #[test]
    fn paths_resolve_to_dense_slots_and_back() {
        let mut r = ParameterRegistry::new();
        let a = r.register("layer.3.opacity", ParamSpec::unit());
        let b = r.register("layer.3.blend.mix", ParamSpec::unit());

        assert_eq!(a.index(), 0);
        assert_eq!(b.index(), 1, "slots must be dense, not sparse");
        assert_eq!(r.resolve("layer.3.opacity"), Some(a));
        assert_eq!(r.path(b), Some("layer.3.blend.mix"));
        assert_eq!(r.resolve("layer.3.opacit"), None, "no prefix matching");
        assert_eq!(r.len(), 2);
    }

    #[test]
    fn re_registering_a_path_keeps_the_slot_and_updates_the_spec() {
        // A document reload must not invalidate slots that are already bound.
        let mut r = ParameterRegistry::new();
        let first = r.register("layer.1.opacity", ParamSpec::unit());
        let again = r.register(
            "layer.1.opacity",
            ParamSpec::unit().with_base(0.25),
        );
        assert_eq!(first, again);
        assert_eq!(r.len(), 1);
        assert_eq!(r.spec(first).expect("spec").base(), 0.25);
    }

    #[test]
    fn unknown_slot_has_no_path_and_no_spec() {
        let r = ParameterRegistry::new();
        assert_eq!(r.path(ParamId(7)), None);
        assert!(r.spec(ParamId(7)).is_none());
        assert!(r.is_empty());
    }

    // ── range nesting invariants ────────────────────────────────────────────

    #[test]
    fn bounds_reject_inverted_and_non_finite() {
        assert!(matches!(
            Bounds::new(1.0, 0.0),
            Err(ModError::Inverted { .. })
        ));
        assert!(matches!(
            Bounds::new(0.0, f64::NAN),
            Err(ModError::NotFinite { .. })
        ));
        assert!(matches!(
            Bounds::new(f64::NEG_INFINITY, 1.0),
            Err(ModError::NotFinite { .. })
        ));
        assert!(Bounds::new(0.0, 0.0).is_ok(), "a pinned parameter is legal");
    }

    #[test]
    fn min_max_must_sit_within_default_range() {
        let spec = ParamSpec::new(Bounds::new(0.0, 1.0).expect("bounds"));
        assert!(matches!(
            spec.with_min_max(Bounds::new(-0.5, 0.5).expect("bounds")),
            Err(ModError::OutsideDefaultRange { .. })
        ));
        assert!(matches!(
            spec.with_min_max(Bounds::new(0.5, 1.5).expect("bounds")),
            Err(ModError::OutsideDefaultRange { .. })
        ));
        assert!(spec
            .with_min_max(Bounds::new(0.2, 0.8).expect("bounds"))
            .is_ok());
    }

    #[test]
    fn start_stop_must_sit_within_min_max() {
        let spec = ParamSpec::unit()
            .with_min_max(Bounds::new(0.2, 0.8).expect("bounds"))
            .expect("narrow");
        assert!(matches!(
            spec.with_start_stop(Sweep::new(0.1, 0.5).expect("sweep")),
            Err(ModError::OutsideMinMax { .. })
        ));
        assert!(matches!(
            spec.with_start_stop(Sweep::new(0.5, 0.9).expect("sweep")),
            Err(ModError::OutsideMinMax { .. })
        ));
        assert!(spec
            .with_start_stop(Sweep::new(0.3, 0.7).expect("sweep"))
            .is_ok());
    }

    #[test]
    fn a_reversed_sweep_is_legal_and_descends() {
        let spec = ParamSpec::unit()
            .with_start_stop(Sweep::new(0.9, 0.1).expect("sweep"))
            .expect("reversed sweep is a setting, not an error");
        assert!(spec.start_stop().is_reversed());
        assert!((spec.value_at(0.0) - 0.9).abs() < 1e-12);
        assert!((spec.value_at(1.0) - 0.1).abs() < 1e-12);
        assert!((spec.value_at(0.5) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn narrowing_min_max_pinches_the_sweep_instead_of_failing() {
        // The operator drags the ceiling down mid-show. It must not error, and
        // the sweep must not be left poking out above the new ceiling.
        let mut spec = ParamSpec::unit()
            .with_start_stop(Sweep::new(0.1, 0.9).expect("sweep"))
            .expect("sweep")
            .with_base(0.95);
        spec.set_min_max(Bounds::new(0.0, 0.5).expect("bounds"))
            .expect("narrowing is always allowed");

        assert_eq!(spec.start_stop().start(), 0.1);
        assert_eq!(spec.start_stop().stop(), 0.5, "sweep top pinched to new max");
        assert_eq!(spec.base(), 0.5, "fader pinched too");
        assert!(spec.min_max().contains_bounds(
            Bounds::new(spec.start_stop().lo(), spec.start_stop().hi()).expect("bounds")
        ));
    }

    #[test]
    fn values_are_clamped_to_min_max_not_to_the_sweep() {
        let spec = ParamSpec::unit()
            .with_min_max(Bounds::new(0.0, 0.4).expect("bounds"))
            .expect("narrow")
            .with_start_stop(Sweep::new(0.0, 0.4).expect("sweep"))
            .expect("sweep");
        // Positions past the ends do not extrapolate past the sweep.
        assert_eq!(spec.value_at(5.0), 0.4);
        assert_eq!(spec.value_at(-5.0), 0.0);
        assert_eq!(spec.value_at(f64::NAN), 0.0, "NaN must not escape");
    }

    #[test]
    fn a_value_never_escapes_min_max_even_when_lerp_overshoots() {
        // These two endpoints are a real case where `start + (stop-start)*1.0`
        // lands one ulp ABOVE `stop`. Without the final clamp a parameter whose
        // ceiling the operator set by hand would be handed a value above it —
        // which downstream is an out-of-gamut colour, an opacity over 1, or an
        // index one past the end.
        let lo = -319.591_225_785_066_9_f64;
        let hi = 266.407_311_727_180_6_f64;
        assert!(lo + (hi - lo) > hi, "this case must actually overshoot");

        let spec = ParamSpec::new(Bounds::new(lo, hi).expect("bounds"));
        assert!(spec.value_at(1.0) <= hi, "value escaped the top of min_max");
        assert!(spec.value_at(0.0) >= lo);

        // And as a property, across the whole sweep.
        for i in 0..=2_000 {
            let v = spec.value_at(f64::from(i) / 2_000.0);
            assert!(spec.min_max().contains(v), "{v} escaped {lo}..{hi}");
        }
    }

    #[test]
    fn base_is_clamped_into_min_max() {
        let spec = ParamSpec::unit()
            .with_min_max(Bounds::new(0.25, 0.75).expect("bounds"))
            .expect("narrow")
            .with_base(10.0);
        assert_eq!(spec.base_value(), 0.75);
        assert_eq!(ParamSpec::unit().with_base(f64::NAN).base(), 0.0);
    }

    // ── LFO phase ───────────────────────────────────────────────────────────

    #[test]
    fn phase_is_exactly_zero_on_every_downbeat() {
        // Bit-exact, not nearly — a four-bar LFO must still fire on the "one"
        // three hours into the set.
        for cycles in [0_i64, 1, 7, 1_000, 1_000_000] {
            let (p, _) = beat_phase(beat(cycles * 4, 1), 4.0, 0.0);
            assert_eq!(p, 0.0, "cycle {cycles} should land exactly on phase 0");
        }
    }

    #[test]
    fn sub_beat_phase_is_exact_through_the_rational_path() {
        // 1/3 of a beat into cycle 100,000 of a 1-beat LFO.
        let (p, _) = beat_phase(beat(300_001, 3), 1.0, 0.0);
        assert_eq!(p, 1.0 / 3.0);
    }

    #[test]
    fn fractional_periods_still_work_through_the_float_path() {
        // 1.5-beat LFO: no integer modulo available, but it must still be right.
        let (p, _) = beat_phase(beat(3, 4), 1.5, 0.0);
        assert!((p - 0.5).abs() < 1e-12);
    }

    #[test]
    fn negative_beats_wrap_forward_not_backward() {
        // Pre-roll before the downbeat must not produce a negative phase.
        let (p, _) = beat_phase(beat(-1, 1), 4.0, 0.0);
        assert_eq!(p, 0.75);
    }

    #[test]
    fn phase_offset_shifts_the_waveform() {
        let (p, _) = beat_phase(beat(0, 1), 4.0, 0.25);
        assert_eq!(p, 0.25);
        let (wrapped, _) = beat_phase(beat(2, 1), 4.0, 0.75);
        assert_eq!(wrapped, 0.25, "offset must wrap, not run off the end");
    }

    #[test]
    fn a_zero_period_freezes_rather_than_dividing_by_zero() {
        let (p, c) = beat_phase(beat(5, 1), 0.0, 0.3);
        assert!(p.is_finite() && c.is_finite());
        assert_eq!(p, 0.3);
    }

    #[test]
    fn waveforms_hit_their_documented_values_at_the_downbeat() {
        assert_eq!(lfo(LfoShape::Sine, 0.0, 0.0, 1), 0.0);
        assert_eq!(lfo(LfoShape::Square, 0.0, 0.0, 1), 1.0, "square is on at the one");
        assert_eq!(lfo(LfoShape::Saw, 0.0, 0.0, 1), -1.0, "saw resets on the one");
        assert_eq!(lfo(LfoShape::Triangle, 0.0, 0.0, 1), -1.0);
    }

    #[test]
    fn waveforms_hit_their_quarter_and_half_points() {
        assert!((lfo(LfoShape::Sine, 0.25, 0.0, 1) - 1.0).abs() < 1e-12);
        assert!(lfo(LfoShape::Sine, 0.5, 0.0, 1).abs() < 1e-12);
        assert!((lfo(LfoShape::Sine, 0.75, 0.0, 1) + 1.0).abs() < 1e-12);
        assert_eq!(lfo(LfoShape::Square, 0.5, 0.0, 1), -1.0);
        assert_eq!(lfo(LfoShape::Saw, 0.5, 0.0, 1), 0.0);
        assert!((lfo(LfoShape::Triangle, 0.5, 0.0, 1) - 1.0).abs() < 1e-12);
        assert!(lfo(LfoShape::Triangle, 0.25, 0.0, 1).abs() < 1e-12);
    }

    #[test]
    fn noise_is_bounded_deterministic_and_actually_moves() {
        let mut seen_low = false;
        let mut seen_high = false;
        for i in 0..400 {
            let c = f64::from(i) * 0.25;
            let v = lfo(LfoShape::Noise, 0.0, c, 99);
            assert!((-1.0..=1.0).contains(&v), "noise escaped its range at {c}");
            assert_eq!(v, lfo(LfoShape::Noise, 0.0, c, 99), "must be repeatable");
            seen_low |= v < -0.3;
            seen_high |= v > 0.3;
        }
        assert!(seen_low && seen_high, "noise must use its range");
        // Different seeds must not move in lockstep.
        assert_ne!(
            lfo(LfoShape::Noise, 0.0, 3.5, 1),
            lfo(LfoShape::Noise, 0.0, 3.5, 2)
        );
    }

    #[test]
    fn noise_is_continuous_across_a_cycle_boundary() {
        let before = lfo(LfoShape::Noise, 0.0, 2.0 - 1e-9, 5);
        let after = lfo(LfoShape::Noise, 0.0, 2.0 + 1e-9, 5);
        assert!(
            (before - after).abs() < 1e-6,
            "value noise must not jump: {before} vs {after}"
        );
    }

    // ── curves ──────────────────────────────────────────────────────────────

    #[test]
    fn every_curve_agrees_at_the_endpoints() {
        for c in [
            Curve::Linear,
            Curve::Exponential,
            Curve::Logarithmic,
            Curve::SCurve,
        ] {
            assert_eq!(apply_curve(c, 0.0), 0.0, "{c:?} at 0");
            assert!((apply_curve(c, 1.0) - 1.0).abs() < 1e-12, "{c:?} at 1");
            assert!((apply_curve(c, -1.0) + 1.0).abs() < 1e-12, "{c:?} at -1");
        }
    }

    #[test]
    fn curves_differ_in_the_middle_in_the_documented_direction() {
        let m = 0.5;
        assert_eq!(apply_curve(Curve::Linear, m), 0.5);
        assert_eq!(apply_curve(Curve::Exponential, m), 0.25);
        assert!((apply_curve(Curve::Logarithmic, m) - 0.5_f64.sqrt()).abs() < 1e-12);
        assert_eq!(apply_curve(Curve::SCurve, m), 0.5, "s-curve is symmetric");
        assert!(apply_curve(Curve::Exponential, 0.25) < apply_curve(Curve::Linear, 0.25));
        assert!(apply_curve(Curve::Logarithmic, 0.25) > apply_curve(Curve::Linear, 0.25));
    }

    #[test]
    fn exponential_and_logarithmic_are_inverses() {
        for x in [0.1, 0.33, 0.5, 0.9] {
            let round = apply_curve(Curve::Logarithmic, apply_curve(Curve::Exponential, x));
            assert!((round - x).abs() < 1e-12, "{x} round-tripped to {round}");
        }
    }

    #[test]
    fn curves_preserve_sign_so_bipolar_sources_stay_symmetric() {
        for c in [Curve::Exponential, Curve::Logarithmic, Curve::SCurve] {
            let up = apply_curve(c, 0.4);
            let down = apply_curve(c, -0.4);
            assert!((up + down).abs() < 1e-12, "{c:?} is asymmetric");
        }
    }

    // ── binding shaping ─────────────────────────────────────────────────────

    fn compiled(polarity: Polarity, invert: bool, curve: Curve) -> Compiled {
        Compiled {
            param: ParamId(0),
            modulator: ModulatorId(0),
            depth: 1.0,
            offset: 0.0,
            curve,
            invert,
            polarity,
        }
    }

    #[test]
    fn invert_is_polarity_aware() {
        // Unipolar inverts around 0.5; bipolar mirrors around 0.
        let uni = compiled(Polarity::Unipolar, true, Curve::Linear);
        assert!((uni.position(0.25) - 0.75).abs() < 1e-12);
        let bi = compiled(Polarity::Bipolar, true, Curve::Linear);
        assert!((bi.position(0.25) + 0.25).abs() < 1e-12);
    }

    #[test]
    fn invert_runs_before_the_curve() {
        // invert(0.25) = 0.75, squared = 0.5625. Curve-then-invert would give
        // 1 - 0.0625 = 0.9375, and the easing would feel different when the
        // operator ticked "invert".
        let b = compiled(Polarity::Unipolar, true, Curve::Exponential);
        assert!((b.position(0.25) - 0.5625).abs() < 1e-12);
    }

    #[test]
    fn a_wild_input_saturates_instead_of_swamping_the_stack() {
        let b = compiled(Polarity::Unipolar, false, Curve::Linear);
        assert_eq!(b.position(1000.0), 1.0);
        assert_eq!(b.position(-1000.0), 0.0);
        assert_eq!(b.position(f64::NAN), 0.0);
    }

    // ── evaluation and stacking ─────────────────────────────────────────────

    #[test]
    fn an_unbound_parameter_reports_its_base() {
        let mut e = ModulationEngine::new();
        let p = e.register("layer.1.opacity", ParamSpec::unit().with_base(0.42));
        e.evaluate(at(0, 1));
        assert_eq!(e.value(p), Some(0.42));
    }

    #[test]
    fn a_full_sweep_bipolar_lfo_covers_exactly_start_to_stop() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        e.spec_mut(p)
            .expect("spec")
            .set_start_stop(Sweep::new(0.2, 0.8).expect("sweep"))
            .expect("sweep");
        let m = e.add_source(&ModSource::BeatLfo {
            shape: LfoShape::Sine,
            beats: 4.0,
            phase: 0.0,
        });
        e.bind_full_sweep(p, m).expect("bind");

        // Sine peaks a quarter of the way through the cycle, troughs at 3/4.
        e.evaluate(at(1, 1));
        assert!((e.value(p).expect("value") - 0.8).abs() < 1e-9, "peak = stop");
        e.evaluate(at(3, 1));
        assert!((e.value(p).expect("value") - 0.2).abs() < 1e-9, "trough = start");
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 0.5).abs() < 1e-9, "centre at the one");
    }

    #[test]
    fn a_full_sweep_unipolar_source_covers_exactly_start_to_stop() {
        let (mut e, p) = unit_engine("fx.1.amount");
        e.spec_mut(p)
            .expect("spec")
            .set_start_stop(Sweep::new(0.25, 0.75).expect("sweep"))
            .expect("sweep");
        let m = e.add_manual(0.0);
        e.bind_full_sweep(p, m).expect("bind");

        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 0.25).abs() < 1e-12);
        e.set_manual(m, 1.0);
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 0.75).abs() < 1e-12);
    }

    #[test]
    fn modulation_replaces_the_base_rather_than_offsetting_it() {
        // Otherwise `offset` means something different depending on where an
        // unrelated fader was left.
        let (mut e, p) = unit_engine("layer.2.opacity");
        e.spec_mut(p).expect("spec").set_base(0.9);
        let m = e.add_manual(0.25);
        e.bind_full_sweep(p, m).expect("bind");
        e.evaluate(at(0, 1));
        assert_eq!(e.value(p), Some(0.25));
    }

    #[test]
    fn bindings_stack_additively_in_sweep_space() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let a = e.add_manual(0.3);
        let b = e.add_manual(0.2);
        e.bind_full_sweep(p, a).expect("bind");
        e.bind_full_sweep(p, b).expect("bind");
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 0.5).abs() < 1e-12);
    }

    #[test]
    fn the_stack_is_clamped_once_not_per_binding() {
        // +0.8 and -0.3 must settle at 0.5. Clamping each binding first would
        // throw the negative one away entirely and leave 0.8.
        let (mut e, p) = unit_engine("layer.1.opacity");
        let up = e.add_manual(0.8);
        let down = e.add_manual(0.3);
        e.bind(Binding::full_sweep(p, up, Polarity::Unipolar))
            .expect("bind");
        e.bind(Binding {
            depth: -1.0,
            ..Binding::full_sweep(p, down, Polarity::Unipolar)
        })
        .expect("bind");
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 0.5).abs() < 1e-12);
    }

    #[test]
    fn stacking_order_is_bind_order_and_it_is_observable() {
        // Float addition is not associative. These three contributions sum to
        // 1.0 or to 0.0 depending purely on order, which is why the rule names
        // an order instead of claiming commutativity.
        let huge = 1.0e16;
        let build = |order: [f64; 3]| {
            let (mut e, p) = unit_engine("layer.1.opacity");
            let one = e.add_manual(1.0);
            for depth in order {
                e.bind(Binding {
                    param: p,
                    modulator: one,
                    depth,
                    offset: 0.0,
                    curve: Curve::Linear,
                    invert: false,
                })
                .expect("bind");
            }
            e.evaluate(at(0, 1));
            e.value(p).expect("value")
        };

        assert_eq!(build([huge, -huge, 1.0]), 1.0);
        assert_eq!(build([huge, 1.0, -huge]), 0.0);
    }

    #[test]
    fn bindings_on_different_parameters_do_not_leak_into_each_other() {
        let mut e = ModulationEngine::new();
        let a = e.register("layer.1.opacity", ParamSpec::unit());
        let b = e.register("layer.2.opacity", ParamSpec::unit());
        let c = e.register("layer.3.opacity", ParamSpec::unit().with_base(0.1));
        let m_a = e.add_manual(0.2);
        let m_b = e.add_manual(0.6);
        // Bound out of slot order on purpose: grouping must be by parameter,
        // not by the order bindings happened to arrive.
        e.bind_full_sweep(b, m_b).expect("bind");
        e.bind_full_sweep(a, m_a).expect("bind");
        e.bind_full_sweep(b, m_a).expect("bind");

        e.evaluate(at(0, 1));
        assert!((e.value(a).expect("value") - 0.2).abs() < 1e-12);
        assert!((e.value(b).expect("value") - 0.8).abs() < 1e-12);
        assert_eq!(e.value(c), Some(0.1), "untouched parameter keeps its base");
    }

    // ── sources through the engine ──────────────────────────────────────────

    #[test]
    fn an_envelope_is_silent_until_triggered_then_rises_and_falls() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let env = e.add_source(&ModSource::Envelope {
            attack_ms: 100.0,
            release_ms: 200.0,
        });
        e.bind_full_sweep(p, env).expect("bind");
        let frame = FrameTime::new(beat(0, 1), 0.01);

        e.evaluate(frame);
        assert_eq!(e.value(p), Some(0.0), "untriggered envelope must be silent");

        e.trigger(env);
        for _ in 0..5 {
            e.evaluate(frame);
        }
        let mid = e.value(p).expect("value");
        assert!((mid - 0.5).abs() < 1e-9, "50ms into a 100ms attack: {mid}");

        // Which frame completes the ramp is approximate — accumulated `dt` is
        // float and ten 10ms steps do not sum to exactly 100ms — but the
        // endpoint is exact, because crossing snaps to 1.0 rather than
        // overshooting into the release.
        for _ in 0..6 {
            e.evaluate(frame);
        }
        assert_eq!(e.value(p), Some(1.0), "attack must reach exactly full");

        for _ in 0..10 {
            e.evaluate(frame);
        }
        let rel = e.value(p).expect("value");
        assert!((rel - 0.5).abs() < 1e-9, "100ms into a 200ms release: {rel}");

        for _ in 0..15 {
            e.evaluate(frame);
        }
        assert_eq!(e.value(p), Some(0.0), "release must settle at exactly zero");
    }

    #[test]
    fn a_zero_millisecond_attack_is_instant() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let env = e.add_source(&ModSource::Envelope {
            attack_ms: 0.0,
            release_ms: 1000.0,
        });
        e.bind_full_sweep(p, env).expect("bind");
        e.trigger(env);
        e.evaluate(FrameTime::new(beat(0, 1), 0.001));
        assert_eq!(e.value(p), Some(1.0));
    }

    #[test]
    fn a_bad_frame_delta_cannot_permanently_kill_an_envelope() {
        // The envelope's level is the one piece of *accumulated* state in the
        // module, so unlike every recomputed signal a single bad frame is
        // forever. NaN fails both stage comparisons, so without the guard the
        // envelope sits at NaN for the rest of the show — masked to silence by
        // the polarity clamp, un-rescuable by `trigger`.
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, -1_000.0, 0.0] {
            let (mut e, p) = unit_engine("layer.1.opacity");
            let env = e.add_source(&ModSource::Envelope {
                attack_ms: 100.0,
                release_ms: 100.0,
            });
            e.bind_full_sweep(p, env).expect("bind");
            e.trigger(env);

            e.evaluate(FrameTime::new(beat(0, 1), bad));
            let after_bad = e.signal(env).expect("signal");
            assert!(
                after_bad.is_finite() && (0.0..=1.0).contains(&after_bad),
                "dt {bad} left the envelope at {after_bad}"
            );

            // Ten good 10 ms frames must complete a 100 ms attack, exactly as
            // if the bad frame had never happened.
            for _ in 0..11 {
                e.evaluate(FrameTime::new(beat(0, 1), 0.01));
            }
            assert_eq!(
                e.value(p),
                Some(1.0),
                "dt {bad} stopped the envelope from ever reaching full"
            );
        }
    }

    #[test]
    fn a_non_finite_lfo_phase_offset_does_not_silence_the_oscillator() {
        // A hand-edited document with `phase: NaN` would otherwise produce a
        // NaN phase every frame, which the polarity clamp turns into a
        // permanently silent LFO that looks like a broken mapping.
        for bad in [f64::NAN, f64::INFINITY] {
            let (mut e, p) = unit_engine("layer.1.opacity");
            let m = e.add_source(&ModSource::BeatLfo {
                shape: LfoShape::Square,
                beats: 1.0,
                phase: bad,
            });
            e.bind_full_sweep(p, m).expect("bind");
            e.evaluate(at(0, 1));
            assert_eq!(e.value(p), Some(1.0), "phase {bad} killed the square wave");
            e.evaluate(at(1, 2));
            assert_eq!(e.value(p), Some(0.0), "phase {bad} killed the square wave");
        }
    }

    #[test]
    fn an_audio_band_follows_its_input_with_attack_and_release() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let band = e.add_source(&ModSource::AudioBand {
            low_hz: 20.0,
            high_hz: 120.0,
            attack_ms: 10.0,
            release_ms: 500.0,
        });
        e.bind_full_sweep(p, band).expect("bind");
        let slot = e.band_slot(20.0, 120.0).expect("band interned a slot");
        let frame = FrameTime::new(beat(0, 1), 1.0 / 60.0);

        e.set_input(slot, 1.0);
        e.evaluate(frame);
        let after_one_frame = e.value(p).expect("value");
        assert!(
            after_one_frame > 0.7,
            "a 10ms attack should be most of the way up in 16ms: {after_one_frame}"
        );

        for _ in 0..5 {
            e.evaluate(frame);
        }
        e.set_input(slot, 0.0);
        let before_release = e.value(p).expect("value");
        e.evaluate(frame);
        let after_release = e.value(p).expect("value");
        assert!(after_release < before_release, "release must fall");
        assert!(
            after_release > 0.9,
            "a 500ms release must barely move in one frame: {after_release}"
        );
    }

    #[test]
    fn a_bad_frame_delta_cannot_snap_an_audio_follower_to_its_input() {
        // `one_pole` answered a bad `dt` the same way it answered a zero time
        // constant — "instant" — so one frame with `dt = 0` threw away the
        // whole attack/release shape and pinned the follower to the raw band
        // level. `dt = 0` arrives from a paused transport, two evaluations in
        // one frame, or the first frame of a show; `dt < 0` from one
        // subtraction the wrong way round. Nothing reports it: the value that
        // comes out is a perfectly ordinary number.
        let (mut e, p) = unit_engine("layer.1.opacity");
        let band = e.add_source(&ModSource::AudioBand {
            low_hz: 20.0,
            high_hz: 120.0,
            attack_ms: 1_000.0,
            release_ms: 1_000.0,
        });
        e.bind_full_sweep(p, band).expect("bind");
        let slot = e.band_slot(20.0, 120.0).expect("slot");
        e.set_input(slot, 1.0);

        for bad in [0.0, -0.5, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut e = e.clone();
            e.evaluate(FrameTime::new(beat(0, 1), bad));
            assert_eq!(
                e.value(p),
                Some(0.0),
                "dt {bad}: a one-second attack moved in a frame that took no time"
            );
        }

        // And the bad frame costs nothing: a good frame afterwards smooths
        // from where the follower actually was, not from where a snap left it.
        e.evaluate(FrameTime::new(beat(0, 1), 0.0));
        e.evaluate(FrameTime::new(beat(0, 1), 1.0 / 60.0));
        let v = e.value(p).expect("value");
        assert!(
            v > 0.0 && v < 0.05,
            "one 16 ms frame of a 1000 ms attack should be ~1.7%, got {v}"
        );
    }

    #[test]
    fn a_zero_millisecond_audio_attack_is_still_instant() {
        // The other half of `one_pole`: a zero *time constant* does mean
        // instant, and splitting the two degenerate cases must not have lost
        // that.
        let (mut e, p) = unit_engine("layer.1.opacity");
        let band = e.add_source(&ModSource::AudioBand {
            low_hz: 20.0,
            high_hz: 120.0,
            attack_ms: 0.0,
            release_ms: 0.0,
        });
        e.bind_full_sweep(p, band).expect("bind");
        let slot = e.band_slot(20.0, 120.0).expect("slot");

        e.set_input(slot, 1.0);
        e.evaluate(FrameTime::new(beat(0, 1), 1.0 / 60.0));
        assert_eq!(e.value(p), Some(1.0));
        e.set_input(slot, 0.0);
        e.evaluate(FrameTime::new(beat(0, 1), 1.0 / 60.0));
        assert_eq!(e.value(p), Some(0.0));
    }

    #[test]
    fn re_registering_a_path_updates_the_value_the_ui_reads_before_the_first_frame() {
        // `ParameterRegistry::register` is idempotent per path precisely so a
        // document reload keeps slots that are already bound. The engine's
        // copy of the value has to follow the new spec, or `value()` reports
        // the previous document's fader position for the whole window between
        // the reload and the next `evaluate` — which is the window the UI
        // draws in.
        let mut e = ModulationEngine::new();
        let a = e.register("a", ParamSpec::unit().with_base(0.3));
        assert_eq!(e.value(a), Some(0.3));

        let again = e.register("a", ParamSpec::unit().with_base(0.9));
        assert_eq!(a, again, "the slot must survive the reload");
        assert_eq!(
            e.value(a),
            Some(0.9),
            "value() must not still be showing the old document's base"
        );
        assert_eq!(e.values(), &[0.9]);

        // And the fast path — a genuinely new path — still appends.
        let b = e.register("b", ParamSpec::unit().with_base(0.1));
        assert_eq!(b.index(), 1);
        assert_eq!(e.values(), &[0.9, 0.1]);
    }

    #[test]
    fn a_pinned_parameter_with_a_zero_width_range_still_evaluates() {
        let (mut e, p) = unit_engine("x");
        e.spec_mut(p)
            .expect("spec")
            .set_min_max(Bounds::new(0.5, 0.5).expect("bounds"))
            .expect("pinning is a legal narrowing");
        let m = e.add_manual(0.3);
        e.bind_full_sweep(p, m).expect("bind");
        e.evaluate(at(0, 1));

        assert_eq!(e.value(p), Some(0.5), "a zero-width window admits one value");
        let spec = *e.params().spec(p).expect("spec");
        assert_eq!(spec.start_stop().start(), 0.5, "the sweep was pinched to fit");
        assert_eq!(spec.start_stop().stop(), 0.5);
        assert_eq!(spec.min_max().span(), 0.0);
    }

    #[test]
    fn a_fractional_period_lfo_does_not_drift_over_a_long_set() {
        // `beat_phase` only takes its exact integer path for whole-beat
        // periods; a 1.5-beat or 1/4-beat LFO goes through the float divide.
        // Three hours at 128 bpm is the case that matters, and the error has
        // to stay far below anything an eye or a strobe could see.
        for (period, per_beat_den) in [(1.5_f64, 5_400_i64), (0.25, 900)] {
            let mut worst = 0.0_f64;
            for frame in (0..648_000_i64).step_by(97) {
                // beat = frame * 128 / 3600, i.e. 128 bpm sampled at 60 fps.
                let (p, _) = beat_phase(beat(frame * 128, 3600), period, 0.0);
                let exact = (frame * 128).rem_euclid(per_beat_den) as f64 / per_beat_den as f64;
                // Circular difference: 0.0 and 1.0 are the same phase.
                worst = worst.max(((p - exact + 0.5).rem_euclid(1.0) - 0.5).abs());
            }
            assert!(
                worst < 1e-9,
                "a {period}-beat LFO drifted by {worst} phase over three hours"
            );
        }
    }

    #[test]
    fn identical_bands_share_one_analyser_slot_but_different_ones_do_not() {
        let mut e = ModulationEngine::new();
        let band = |low: f64, high: f64| ModSource::AudioBand {
            low_hz: low,
            high_hz: high,
            attack_ms: 5.0,
            release_ms: 5.0,
        };
        e.add_source(&band(20.0, 120.0));
        e.add_source(&band(20.0, 120.0));
        e.add_source(&band(20.0, 121.0));
        assert_eq!(e.audio_bands().count(), 2);
        assert_eq!(e.band_slot(20.0, 120.0), Some(InputSlot(0)));
        assert_eq!(e.band_slot(20.0, 121.0), Some(InputSlot(1)));
        assert_eq!(e.band_slot(30.0, 120.0), None);
    }

    #[test]
    fn midi_and_osc_resolve_to_dense_slots() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let cc = e.add_source(&ModSource::MidiCc {
            channel: 0,
            cc: 74,
        });
        let osc = e.add_source(&ModSource::Osc {
            address: "/photon/layer/1/opacity".into(),
        });
        e.bind_full_sweep(p, cc).expect("bind");

        assert!(e.set_midi_cc(0, 74, 127));
        assert!(!e.set_midi_cc(0, 75, 127), "unmapped CC must report unmapped");
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 1.0).abs() < 1e-12);

        assert!(e.set_midi_cc(0, 74, 64));
        e.evaluate(at(0, 1));
        assert!((e.value(p).expect("value") - 64.0 / 127.0).abs() < 1e-12);

        assert!(e.set_osc("/photon/layer/1/opacity", 0.5));
        assert!(!e.set_osc("/photon/nope", 0.5));
        e.evaluate(at(0, 1));
        assert_eq!(e.signal(osc), Some(0.5));
    }

    #[test]
    fn a_rogue_input_cannot_make_a_parameter_non_finite() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let osc = e.add_source(&ModSource::Osc {
            address: "/x".into(),
        });
        e.bind_full_sweep(p, osc).expect("bind");
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY, 1e300] {
            e.set_osc("/x", bad);
            e.evaluate(at(0, 1));
            let v = e.value(p).expect("value");
            assert!(v.is_finite(), "{bad} produced {v}");
            assert!((0.0..=1.0).contains(&v));
        }
    }

    // ── load path ───────────────────────────────────────────────────────────

    #[test]
    fn a_document_binding_loads_by_path_and_then_runs_on_slots() {
        let mut e = ModulationEngine::new();
        let p = e.register("layer.3.opacity", ParamSpec::unit());
        let doc_binding = doc::Binding {
            target: "layer.3.opacity".into(),
            source: ModSource::BeatLfo {
                shape: LfoShape::Square,
                beats: 1.0,
                phase: 0.0,
            },
            depth: 0.5,
            offset: 0.5,
            curve: Curve::Linear,
            invert: false,
        };
        let m = e.bind_document(&doc_binding).expect("load");
        assert_eq!(e.polarity(m), Some(Polarity::Bipolar));

        e.evaluate(at(0, 1));
        assert_eq!(e.value(p), Some(1.0), "square is high on the beat");
        e.evaluate(at(1, 2));
        assert_eq!(e.value(p), Some(0.0), "and low on the off-beat");
    }

    #[test]
    fn a_document_binding_to_an_unknown_path_fails_loudly() {
        let mut e = ModulationEngine::new();
        e.register("layer.1.opacity", ParamSpec::unit());
        let err = e
            .bind_document(&doc::Binding {
                target: "layer.9.opacity".into(),
                source: ModSource::MidiCc {
                    channel: 0,
                    cc: 1,
                },
                depth: 1.0,
                offset: 0.0,
                curve: Curve::Linear,
                invert: false,
            })
            .expect_err("missing parameter must not be silently dropped");
        assert_eq!(err, ModError::UnknownPath("layer.9.opacity".into()));
        assert_eq!(e.binding_count(), 0);
    }

    #[test]
    fn a_rejected_document_binding_leaves_no_orphan_source() {
        let mut e = ModulationEngine::new();
        e.register("layer.1.opacity", ParamSpec::unit());
        let err = e
            .bind_document(&doc::Binding {
                target: "layer.1.opacity".into(),
                source: ModSource::MidiCc {
                    channel: 0,
                    cc: 1,
                },
                depth: f64::NAN,
                offset: 0.0,
                curve: Curve::Linear,
                invert: false,
            })
            .expect_err("NaN depth must be rejected");
        assert!(matches!(err, ModError::NotFinite { .. }));
        assert_eq!(e.modulators.len(), 0, "no source should have been created");
        assert_eq!(e.inputs.len(), 0, "and no input slot either");
    }

    #[test]
    fn binding_rejects_ids_from_elsewhere() {
        let (mut e, p) = unit_engine("layer.1.opacity");
        let m = e.add_manual(0.5);
        assert_eq!(
            e.bind(Binding::full_sweep(ParamId(9), m, Polarity::Unipolar)),
            Err(ModError::UnknownParam(9))
        );
        assert_eq!(
            e.bind(Binding::full_sweep(p, ModulatorId(9), Polarity::Unipolar)),
            Err(ModError::UnknownModulator(9))
        );
        assert_eq!(e.binding_count(), 0);
    }

    // ── frame-loop properties ───────────────────────────────────────────────

    #[test]
    fn evaluation_does_not_reallocate() {
        // A counting allocator would need `unsafe`, which this crate forbids.
        // Pinning pointers and capacities catches the same failure: any push,
        // resize or re-collect inside the frame loop moves or grows a buffer.
        let mut e = ModulationEngine::new();
        let mut params = Vec::new();
        for i in 0..32 {
            params.push(e.register(&format!("layer.{i}.opacity"), ParamSpec::unit()));
        }
        for (i, p) in params.iter().enumerate() {
            let lfo = e.add_source(&ModSource::BeatLfo {
                shape: LfoShape::Sine,
                beats: 4.0,
                phase: 0.0,
            });
            let env = e.add_source(&ModSource::Envelope {
                attack_ms: 20.0,
                release_ms: 300.0,
            });
            let band = e.add_source(&ModSource::AudioBand {
                low_hz: 20.0 + i as f64,
                high_hz: 200.0,
                attack_ms: 10.0,
                release_ms: 100.0,
            });
            let cc = e.add_source(&ModSource::MidiCc {
                channel: 0,
                cc: i as u8,
            });
            for m in [lfo, env, band, cc] {
                e.bind_full_sweep(*p, m).expect("bind");
            }
            e.trigger(env);
        }

        // Give every buffer slack *before* pinning it. Without this the test
        // only worked by luck: setup happened to leave each `Vec` exactly
        // full, so a stray `push` had to reallocate to be seen. With spare
        // capacity a push moves neither the pointer nor the capacity — only
        // the length — so the length is pinned too.
        e.values.reserve(16);
        e.signals.reserve(16);
        e.inputs.reserve(16);
        e.bindings.reserve(16);

        let values = (e.values.as_ptr(), e.values.capacity(), e.values.len());
        let signals = (e.signals.as_ptr(), e.signals.capacity(), e.signals.len());
        let inputs = (e.inputs.as_ptr(), e.inputs.capacity(), e.inputs.len());
        let bindings = (e.bindings.as_ptr(), e.bindings.capacity(), e.bindings.len());

        for frame in 0..5_000_i64 {
            e.set_midi_cc(0, 3, (frame % 128) as u8);
            e.evaluate(FrameTime::new(beat(frame, 60), 1.0 / 60.0));
        }

        assert_eq!(
            (e.values.as_ptr(), e.values.capacity(), e.values.len()),
            values
        );
        assert_eq!(
            (e.signals.as_ptr(), e.signals.capacity(), e.signals.len()),
            signals
        );
        assert_eq!(
            (e.inputs.as_ptr(), e.inputs.capacity(), e.inputs.len()),
            inputs
        );
        assert_eq!(
            (e.bindings.as_ptr(), e.bindings.capacity(), e.bindings.len()),
            bindings
        );
    }

    #[test]
    fn a_beat_locked_lfo_does_not_drift_over_a_long_set() {
        // Three hours at 128 bpm is ~23,000 beats. Phase comes from absolute
        // musical time, so frame count and frame rate cannot accumulate error.
        let (mut e, p) = unit_engine("layer.1.opacity");
        let m = e.add_source(&ModSource::BeatLfo {
            shape: LfoShape::Saw,
            beats: 4.0,
            phase: 0.0,
        });
        e.bind_full_sweep(p, m).expect("bind");

        for bar in 0..6_000_i64 {
            // Deliberately irregular frame deltas — a musical LFO must not care.
            e.evaluate(FrameTime::new(beat(bar * 4, 1), 1.0 / (30 + bar % 90) as f64));
            assert_eq!(
                e.value(p),
                Some(0.0),
                "saw must reset exactly on bar {bar}'s downbeat"
            );
        }
    }

    #[test]
    fn values_are_readable_before_the_first_frame() {
        // The UI draws before the clock has ticked; it must show the fader
        // positions, not black.
        let mut r = ParameterRegistry::new();
        let a = r.register("a", ParamSpec::unit().with_base(0.3));
        let e = ModulationEngine::with_params(r);
        assert_eq!(e.value(a), Some(0.3));

        let mut e = ModulationEngine::new();
        let b = e.register("b", ParamSpec::unit().with_base(0.7));
        assert_eq!(e.value(b), Some(0.7));
    }

    #[test]
    fn values_slice_matches_per_parameter_lookup() {
        let mut e = ModulationEngine::new();
        let a = e.register("a", ParamSpec::unit().with_base(0.1));
        let b = e.register("b", ParamSpec::unit().with_base(0.2));
        e.evaluate(at(0, 1));
        assert_eq!(e.values(), &[0.1, 0.2]);
        assert_eq!(e.value(a), Some(0.1));
        assert_eq!(e.value(b), Some(0.2));
        assert_eq!(e.value(ParamId(99)), None);
    }
}
