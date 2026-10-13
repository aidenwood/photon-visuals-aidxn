//! The `.photon` document — **the single source of truth** for project state.
//!
//! Every consumer (macOS shell, Windows shell, remote clients, bench harness)
//! derives its types from this definition. Swift types are generated from the
//! emitted JSON Schema and CI fails on drift; nothing is hand-written twice.
//!
//! ## Design rules fixed at R0
//!
//! - **Rational time, never floats.** Frame rates and timestamps are exact
//!   ratios ([`Rational`]). 30000/1001 is not 29.97, and accumulated float
//!   drift across a three-hour set is a real, un-debuggable failure.
//! - **Stable IDs.** Every object carries an opaque, persistent [`Id`].
//!   Readable parameter *paths* persist; they resolve to dense runtime slots on
//!   load. No path parsing in the frame loop.
//! - **Colour is described, never assumed.** Every source carries a full
//!   [`ColorDescriptor`]. Retrofitting colour correctness is a rewrite.
//! - **Mapping and patch live in separate documents.** The same show travels to
//!   a different venue with a different rig.
//! - **Versioned JSON only.** CBOR is deferred until measured load time
//!   justifies a second serialisation.

use serde::{Deserialize, Serialize};

mod color;
mod ids;
mod rational;

pub use color::{AlphaMode, ColorDescriptor, MatrixCoefficients, Primaries, Range, Transfer};
pub use ids::{Id, IdAllocator};
pub use rational::Rational;

/// Schema version of the `.photon` document format.
///
/// Bumped on any breaking change; migrations are keyed off it.
///
/// **v1** added the per-layer Resolume-parity block ([`Layer::playback`],
/// [`Layer::transform`], [`Layer::transition`], [`Layer::autopilot`],
/// [`Layer::crossfader_group`], [`Layer::fader_start`],
/// [`Layer::ignore_column_trigger`]). Every one of those fields carries
/// `#[serde(default)]`, so **a v0 document loads into a v1 build unchanged** —
/// the defaults *are* the migration and no migration code exists or is needed.
///
/// The bump is for the other direction. [`Document`] is
/// `deny_unknown_fields`, so a v0 build handed a v1 file would otherwise fail
/// with `unknown field "playback"`, which tells an operator standing in a venue
/// nothing. With the bump it fails with "saved by a newer version", which tells
/// them exactly what to do. That is the entire job of this constant.
pub const SCHEMA_VERSION: u32 = 1;

/// A complete Photon project.
///
/// Excludes output mapping and fixture patch by design — those are separate
/// documents so a show can move between venues.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Document {
    /// Format version. Must equal [`SCHEMA_VERSION`] or be migrated.
    pub schema_version: u32,
    /// Project metadata.
    pub meta: Meta,
    /// The mix canvas these layers composite into.
    pub composition: Composition,
    /// Tempo and phase configuration.
    pub clock: ClockConfig,
    /// Layer stack, index 0 = bottom.
    pub layers: Vec<Layer>,
    /// Clips referenced by layers.
    pub clips: Vec<Clip>,
    /// Media and generator sources referenced by clips.
    pub sources: Vec<Source>,
    /// Parameter modulation bindings.
    pub modulation: Vec<Binding>,
}

/// Project metadata.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Meta {
    /// Human-readable project name.
    pub name: String,
    /// RFC 3339 creation timestamp.
    pub created: String,
    /// RFC 3339 last-modified timestamp.
    pub modified: String,
    /// `photon-core` version that last wrote this file.
    pub written_by: String,
}

/// The mix canvas.
///
/// Distinct from both *source* resolution and *output* topology — a
/// four-projector rig is a 7680×1080 composition fed by 1080p sources. GPU cost
/// scales with this; disk and decode cost scale with source resolution.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Composition {
    /// Canvas width in pixels.
    pub width: u32,
    /// Canvas height in pixels.
    pub height: u32,
    /// Target composition cadence, exact.
    pub rate: Rational,
    /// Working colour space. Compositing is done in linear light; see
    /// `V3-merged.md` §3.2b for why sRGB blending breaks soft-edge.
    pub working_space: WorkingSpace,
}

/// Working colour space for the compositor.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum WorkingSpace {
    /// Linear light, 16-bit float targets. The default and the only correct
    /// choice for soft-edge blending and physically-sensible blend modes.
    #[default]
    LinearRgba16F,
}

/// Tempo and phase configuration.
///
/// Tempo and phase are **separable sources** — rekordbox supplies usable BPM
/// over Ableton Link but not a reliable downbeat, so the engine must accept
/// them from different places. See `V3-merged.md` §2.4b2.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ClockConfig {
    /// Beats per minute.
    pub bpm: f64,
    /// Where tempo comes from.
    pub tempo_source: TempoSource,
    /// Where the downbeat comes from. May differ from `tempo_source`.
    pub phase_source: PhaseSource,
    /// Default launch quantisation for clip triggers.
    pub quantise: Quantise,
}

/// Source of tempo.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum TempoSource {
    /// Fixed BPM set in the document.
    #[default]
    Manual,
    /// Operator tap tempo.
    Tap,
    /// MIDI clock from a mixer, DAW or drum machine.
    MidiClock,
    /// Ableton Link. Deferred to Photon 3.0/4.0; requires a commercial licence.
    AbletonLink,
}

/// Source of beat phase (the downbeat).
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum PhaseSource {
    /// Derived from the tempo source's own phase, where it has one.
    #[default]
    FollowTempo,
    /// Operator tap.
    Tap,
    /// MIDI song-position pointer.
    MidiSpp,
    /// Pioneer Pro DJ Link. Deferred; the reliable phase source for CDJ rigs.
    ProDjLink,
}

/// Launch quantisation, in beats. `None` triggers immediately.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Quantise {
    /// Trigger immediately, no quantisation.
    Immediate,
    /// Next beat.
    Beat,
    /// Next bar (4 beats).
    #[default]
    Bar,
    /// Next N bars.
    Bars(u8),
}

/// One layer in the stack.
///
/// The fields below `solo` are the Resolume-parity block added in schema v1.
/// All of them are `#[serde(default)]`, so a v0 document still loads — see
/// [`SCHEMA_VERSION`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Layer {
    /// Stable identity.
    pub id: Id,
    /// Display name.
    pub name: String,
    /// 0.0–1.0. This is the **layer master fader** — Resolume's `master`, the
    /// one the operator actually rides. A clip's own opacity is a separate
    /// value and multiplies with it; it is not modelled here because it
    /// belongs to [`Clip`].
    pub opacity: f64,
    /// How this layer combines with the accumulated result beneath it.
    pub blend: BlendMode,
    /// Currently active clip, if any.
    pub clip: Option<Id>,
    /// Excluded from the composite.
    pub bypass: bool,
    /// Soloed; when any layer is soloed, non-soloed layers are excluded.
    pub solo: bool,

    /// Layer-level playback override. `None` means **follow the clip**.
    ///
    /// Resolume surfaces a transport strip on the layer (the "Layer Transport
    /// Controls" toggle) and in Arena that strip edits whichever clip is
    /// currently active — so reaching for it mid-set changes one clip and
    /// silently leaves the next one on whatever it was saved with. Setting it
    /// here instead makes the layer the authority, which is what an operator
    /// means when they say "this layer bounces": every clip that lands on it
    /// bounces, including ones not triggered yet.
    ///
    /// Resolve it with [`Layer::resolved_playback`] rather than reading this
    /// field directly — the precedence is the whole point of it existing.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub playback: Option<PlaybackMode>,

    /// Position, scale, rotation and anchor applied to everything the layer
    /// draws, before blending.
    ///
    /// Arena models this as a non-removable `Transform` effect pinned at the
    /// head of each layer's render-pass chain. We model it as plain layer state
    /// because there is no effect chain in this document yet, and because a
    /// transform that can be reordered or deleted is a footgun on a layer a VJ
    /// has already mapped to output.
    #[serde(default)]
    pub transform: Transform2D,

    /// Which side of the crossfader this layer belongs to.
    #[serde(default)]
    pub crossfader_group: CrossfaderGroup,

    /// Column triggers skip this layer.
    ///
    /// The reason it exists: one layer holds a logo, a mask or a lighting cue
    /// that must survive a column change. Without this, firing a column wipes
    /// it and the operator has to re-trigger it every time.
    #[serde(default)]
    pub ignore_column_trigger: bool,

    /// Raising the fader off zero triggers the active clip; dropping it to zero
    /// stops the clip rather than just hiding it.
    ///
    /// This is a decode-cost decision as much as a workflow one — a faded-out
    /// layer with fader start off is still decoding every frame.
    #[serde(default)]
    pub fader_start: bool,

    /// How this layer crossfades from the outgoing clip to a newly triggered
    /// one.
    #[serde(default)]
    pub transition: LayerTransition,

    /// Automatic clip advance. `None` means off, which is the default and the
    /// only safe default — a layer that advances on its own without being asked
    /// is a surprise in front of an audience.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub autopilot: Option<AutoPilot>,
}

impl Layer {
    /// The playback behaviour that actually applies, layer override first.
    ///
    /// Precedence, highest to lowest:
    /// 1. [`Layer::playback`], when set — the layer wins outright.
    /// 2. The clip's own [`Clip::transport`] / [`Clip::playthrough`].
    /// 3. The type defaults, when the layer has no clip at all.
    ///
    /// Returned as the `(Transport, Playthrough)` pair the engine already
    /// consumes, so the override lives in exactly one place and the frame loop
    /// never learns that layer-level playback exists.
    #[must_use]
    pub fn resolved_playback(&self, clip: Option<&Clip>) -> (Transport, Playthrough) {
        match self.playback {
            Some(mode) => mode.resolve(),
            None => match clip {
                Some(c) => (c.transport, c.playthrough),
                None => (Transport::default(), Playthrough::default()),
            },
        }
    }
}

/// A 2D point or pair of factors, in normalised composition units.
///
/// Normalised rather than pixels so a composition can be re-targeted from
/// 1920×1080 to a 7680×1080 four-projector canvas without every layer's
/// position becoming wrong.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Vec2 {
    /// Horizontal component.
    pub x: f64,
    /// Vertical component.
    pub y: f64,
}

impl Vec2 {
    /// Both components zero — the composition centre, for a position or anchor.
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };
    /// Both components one — unscaled, for a scale factor.
    pub const ONE: Self = Self { x: 1.0, y: 1.0 };
}

/// Per-layer geometry, applied before blending.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Transform2D {
    /// Offset from the composition centre. `(0, 0)` is centred; `(1, 0)` is one
    /// full composition width to the right.
    pub position: Vec2,
    /// Scale factors. `(1, 1)` is unscaled. Negative values flip.
    pub scale: Vec2,
    /// Rotation about [`Transform2D::anchor`], in degrees, anticlockwise.
    ///
    /// Degrees and not radians because this number appears on a control
    /// surface and gets typed in by hand; 90 is a right angle and 1.5707963 is
    /// a bug report.
    pub rotation_deg: f64,
    /// The point scale and rotation pivot around, relative to the layer centre
    /// in the same units as [`Transform2D::position`].
    pub anchor: Vec2,
}

impl Default for Transform2D {
    fn default() -> Self {
        Self {
            position: Vec2::ZERO,
            scale: Vec2::ONE,
            rotation_deg: 0.0,
            anchor: Vec2::ZERO,
        }
    }
}

impl Transform2D {
    /// Whether this transform is the identity.
    ///
    /// The compositor uses this to skip a sampling pass entirely, which is why
    /// it is exact equality and not an epsilon: a transform a hair off identity
    /// genuinely does need resampling, and silently snapping it would make a
    /// deliberate one-pixel nudge impossible.
    #[must_use]
    pub fn is_identity(&self) -> bool {
        *self == Self::default()
    }
}

/// Crossfader assignment.
///
/// A layer in a group is scaled by that side of the crossfader;
/// [`CrossfaderGroup::None`] means the crossfader never touches it, which is
/// the right default for mask and overlay layers.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum CrossfaderGroup {
    /// Unassigned — unaffected by crossfader position.
    #[default]
    None,
    /// Side A.
    A,
    /// Side B.
    B,
}

/// How a layer crossfades from the outgoing clip to a newly triggered one.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct LayerTransition {
    /// Crossfade length. Zero is a hard cut, and is the default — an
    /// unrequested fade on every trigger is worse than a cut.
    pub duration: Rational,
    /// How the incoming clip is mixed over the outgoing one during the fade.
    ///
    /// Reuses [`BlendMode`] deliberately: Resolume draws clip transitions from
    /// the same pool of mixers as layer blend modes, and duplicating the list
    /// is how the two definitions start to drift.
    pub blend: BlendMode,
}

impl Default for LayerTransition {
    fn default() -> Self {
        Self {
            duration: Rational::new(0, 1),
            blend: BlendMode::Over,
        }
    }
}

/// Automatic clip advance on a layer.
///
/// Resolume calls this Autopilot. It is the unattended-playback feature: the
/// layer moves itself through clips so an operator can leave the desk.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AutoPilot {
    /// Which clip to move to.
    pub target: AutoPilotTarget,
    /// When to move.
    pub after: AutoPilotTrigger,
    /// Wrap around at the end of the layer instead of stopping there.
    pub cycle: bool,
}

/// Which clip autopilot moves to.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum AutoPilotTarget {
    /// The next clip to the right in this layer.
    #[default]
    Next,
    /// The previous clip to the left in this layer.
    Previous,
    /// Any other clip in the layer, chosen at random.
    Random,
    /// One specific clip, every time. Useful as a return-to-idle.
    Specific(Id),
}

/// What makes autopilot advance.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AutoPilotTrigger {
    /// After a number of musical beats. Tempo-locked, so it stays in time if
    /// the BPM moves.
    Beats(u16),
    /// After a wall-clock duration.
    Seconds(Rational),
    /// After the clip has played through a number of times. The only option
    /// that respects clips of differing lengths.
    Loops(u16),
}

impl Default for AutoPilotTrigger {
    fn default() -> Self {
        // One full play-through: the choice that never cuts a clip mid-phrase,
        // whatever lengths are loaded.
        Self::Loops(1)
    }
}

/// Per-layer playback mode, named the way an operator names it.
///
/// This is the one type in the document that exists for *vocabulary* rather
/// than structure. [`Transport`] and [`Playthrough`] are the correct
/// decomposition for the engine — direction-of-time and end-of-clip are
/// genuinely independent — but no VJ composes them. They say "bpm bounce". Six
/// names, one control, and the composition happens in [`PlaybackMode::resolve`]
/// so the engine still has exactly one implementation of each behaviour.
///
/// The six are the full cross product of the three loop shapes Resolume ships
/// (loop, bounce, random) against free-running and tempo-locked time.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum PlaybackMode {
    /// Play forwards, restart at the end. Free-running.
    #[default]
    Loop,
    /// Play forwards to the end, then backwards to the start, repeatedly.
    /// Free-running.
    Bounce,
    /// Jump to a random position instead of running continuously.
    /// Free-running.
    RandomSkip,
    /// Loop, with the loop length locked to musical time.
    BpmSync {
        /// Loop length in beats.
        beats: u16,
    },
    /// Bounce, with the sweep length locked to musical time.
    BpmBounce {
        /// Sweep length in beats.
        beats: u16,
    },
    /// Random skip, quantised so each jump lands on the beat.
    BpmSkip {
        /// Interval between jumps, in beats.
        beats: u16,
    },
}

impl PlaybackMode {
    /// Decompose into the pair the engine runs on.
    ///
    /// Lossless in this direction; [`PlaybackMode::from_parts`] is the partial
    /// inverse.
    #[must_use]
    pub const fn resolve(self) -> (Transport, Playthrough) {
        match self {
            Self::Loop => (Transport::Timeline, Playthrough::Loop),
            Self::Bounce => (Transport::Timeline, Playthrough::PingPong),
            Self::RandomSkip => (Transport::Timeline, Playthrough::Random),
            Self::BpmSync { beats } => (Transport::BpmSync { beats }, Playthrough::Loop),
            Self::BpmBounce { beats } => (Transport::BpmSync { beats }, Playthrough::PingPong),
            Self::BpmSkip { beats } => (Transport::BpmSync { beats }, Playthrough::Random),
        }
    }

    /// Name an existing `(Transport, Playthrough)` pair as one of the six, if
    /// it is one of the six.
    ///
    /// Returns `None` for pairs the six names cannot describe —
    /// [`Transport::Position`] (externally driven, so no loop shape applies)
    /// and [`Playthrough::Once`] / [`Playthrough::HoldLast`] (not loops at
    /// all). A UI showing a clip's current mode must handle that `None` by
    /// showing the clip's own controls, **not** by picking the nearest of the
    /// six — silently rewriting a one-shot into a loop is a mode a user did not
    /// ask for.
    #[must_use]
    pub const fn from_parts(transport: Transport, playthrough: Playthrough) -> Option<Self> {
        match (transport, playthrough) {
            (Transport::Timeline, Playthrough::Loop) => Some(Self::Loop),
            (Transport::Timeline, Playthrough::PingPong) => Some(Self::Bounce),
            (Transport::Timeline, Playthrough::Random) => Some(Self::RandomSkip),
            (Transport::BpmSync { beats }, Playthrough::Loop) => Some(Self::BpmSync { beats }),
            (Transport::BpmSync { beats }, Playthrough::PingPong) => {
                Some(Self::BpmBounce { beats })
            }
            (Transport::BpmSync { beats }, Playthrough::Random) => Some(Self::BpmSkip { beats }),
            _ => None,
        }
    }

    /// Whether this mode is tempo-locked.
    ///
    /// Cheaper and clearer at call sites than matching three variants, and it
    /// is the question the clock actually asks.
    #[must_use]
    pub const fn is_tempo_locked(self) -> bool {
        matches!(
            self,
            Self::BpmSync { .. } | Self::BpmBounce { .. } | Self::BpmSkip { .. }
        )
    }
}

/// Layer blend modes.
///
/// Marked [`BlendMode::needs_destination`] where the mode must read the
/// accumulated result beneath it. Those cannot be expressed by Metal's
/// fixed-function blending and force the register-folding compositor path —
/// see `V3-merged.md` §1.3.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum BlendMode {
    #[default]
    Over,
    Add,
    Multiply,
    Screen,
    Difference,
    Mask,
    Overlay,
    HardLight,
    Subtract,
    Lighten,
    Darken,
}

impl BlendMode {
    /// Whether this mode needs to read the destination.
    ///
    /// `false` means it is expressible in fixed-function blending, so a stack
    /// of only these can use ordinary ordered draws. One `true` anywhere in the
    /// stack forces the register-folded path for the whole stack.
    #[must_use]
    pub const fn needs_destination(self) -> bool {
        !matches!(
            self,
            Self::Over | Self::Add | Self::Multiply | Self::Screen | Self::Lighten | Self::Darken
        )
    }
}

/// A clip: a source plus how it plays.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Clip {
    /// Stable identity.
    pub id: Id,
    /// Display name.
    pub name: String,
    /// The media or generator this clip plays.
    pub source: Id,
    /// How playback is driven.
    pub transport: Transport,
    /// What happens at the end.
    pub playthrough: Playthrough,
    /// Trim in point.
    pub trim_in: Rational,
    /// Trim out point.
    pub trim_out: Rational,
}

/// How a clip's playback position is driven. Resolume calls this "transport".
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum Transport {
    /// Free-running at the clip's own rate. Not tempo-locked.
    #[default]
    Timeline,
    /// Loop length quantised to musical time; playback rate derived from tempo
    /// so the clip always lands on the beat.
    BpmSync {
        /// Loop length in beats.
        beats: u16,
    },
    /// Position driven directly by a parameter, so it can be modulated.
    Position,
}

/// End-of-clip behaviour.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum Playthrough {
    #[default]
    Loop,
    Once,
    PingPong,
    Random,
    HoldLast,
}

/// A media file or generator.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Source {
    /// Stable identity.
    pub id: Id,
    /// What kind of source this is.
    pub kind: SourceKind,
    /// Location — file path, Syphon server name, NDI name, device id.
    pub uri: String,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
    /// Native cadence, exact. `None` for live sources with no fixed rate.
    pub rate: Option<Rational>,
    /// Full colour description. Mandatory — never inferred.
    pub color: ColorDescriptor,
}

/// Kind of source.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum SourceKind {
    /// A media file on disk.
    File,
    /// Inter-app video in (Syphon on macOS, Spout on Windows).
    InterApp,
    /// NDI network source.
    Ndi,
    /// Capture device or card.
    Capture,
    /// Screen or window capture.
    ScreenCapture,
    /// Internally generated.
    Generator,
}

/// A modulation binding: one source driving one parameter.
///
/// Beat sync, audio reactivity and MIDI mapping are the same mechanism. The
/// readable `target` path persists; it resolves to a dense runtime slot on load
/// so the frame loop never parses a string.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Binding {
    /// Readable parameter path, e.g. `layer.3.opacity`.
    pub target: String,
    /// What drives it.
    pub source: ModSource,
    /// Scale applied to the source value.
    pub depth: f64,
    /// Added after scaling.
    pub offset: f64,
    /// Response shape.
    pub curve: Curve,
    /// Invert the source value.
    pub invert: bool,
}

/// A modulation source.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", tag = "type")]
pub enum ModSource {
    /// Audio band envelope.
    AudioBand {
        /// Low edge, Hz.
        low_hz: f64,
        /// High edge, Hz.
        high_hz: f64,
        /// Attack, milliseconds.
        attack_ms: f64,
        /// Release, milliseconds.
        release_ms: f64,
    },
    /// Oscillator synced to musical time.
    BeatLfo {
        /// Waveform.
        shape: LfoShape,
        /// Period in beats.
        beats: f64,
        /// Phase offset, 0.0–1.0.
        phase: f64,
    },
    /// MIDI continuous controller.
    MidiCc {
        /// MIDI channel, 0–15.
        channel: u8,
        /// Controller number, 0–127.
        cc: u8,
    },
    /// OSC address.
    Osc {
        /// OSC address pattern.
        address: String,
    },
    /// Envelope triggered on clip launch.
    Envelope {
        /// Attack, milliseconds.
        attack_ms: f64,
        /// Release, milliseconds.
        release_ms: f64,
    },
}

/// LFO waveform.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum LfoShape {
    Sine,
    Saw,
    Square,
    Triangle,
    Noise,
}

/// Response curve applied to a modulation value.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
#[allow(missing_docs)]
pub enum Curve {
    #[default]
    Linear,
    Exponential,
    Logarithmic,
    SCurve,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed_function_blends_do_not_need_destination() {
        for m in [
            BlendMode::Over,
            BlendMode::Add,
            BlendMode::Multiply,
            BlendMode::Screen,
        ] {
            assert!(!m.needs_destination(), "{m:?} should be fixed-function");
        }
    }

    #[test]
    fn mask_and_difference_need_destination() {
        // These are the modes that force the register-folded compositor.
        assert!(BlendMode::Mask.needs_destination());
        assert!(BlendMode::Difference.needs_destination());
        assert!(BlendMode::Overlay.needs_destination());
    }

    #[test]
    fn document_round_trips_through_json() {
        let doc = Document {
            schema_version: SCHEMA_VERSION,
            meta: Meta {
                name: "test".into(),
                created: "2026-10-12T00:00:00Z".into(),
                modified: "2026-10-12T00:00:00Z".into(),
                written_by: crate::VERSION.into(),
            },
            composition: Composition {
                width: 1920,
                height: 1080,
                rate: Rational::new(60, 1),
                working_space: WorkingSpace::default(),
            },
            clock: ClockConfig {
                bpm: 128.0,
                tempo_source: TempoSource::Tap,
                phase_source: PhaseSource::FollowTempo,
                quantise: Quantise::Bar,
            },
            layers: vec![],
            clips: vec![],
            sources: vec![],
            modulation: vec![],
        };
        let json = serde_json::to_string(&doc).expect("serialise");
        let back: Document = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(doc, back);
    }

    fn layer(id: u64) -> Layer {
        Layer {
            id: Id::new(id),
            name: "L".into(),
            opacity: 1.0,
            blend: BlendMode::Over,
            clip: None,
            bypass: false,
            solo: false,
            playback: None,
            transform: Transform2D::default(),
            crossfader_group: CrossfaderGroup::default(),
            ignore_column_trigger: false,
            fader_start: false,
            transition: LayerTransition::default(),
            autopilot: None,
        }
    }

    fn clip(transport: Transport, playthrough: Playthrough) -> Clip {
        Clip {
            id: Id::new(900),
            name: "C".into(),
            source: Id::new(901),
            transport,
            playthrough,
            trim_in: Rational::new(0, 1),
            trim_out: Rational::new(10, 1),
        }
    }

    // ── per-layer playback ──────────────────────────────────────────────

    #[test]
    fn the_six_modes_decompose_to_the_pairs_the_engine_runs_on() {
        // These six names are the user-facing vocabulary; this is the only
        // place the mapping to (Transport, Playthrough) is defined.
        let cases = [
            (PlaybackMode::Loop, Transport::Timeline, Playthrough::Loop),
            (
                PlaybackMode::Bounce,
                Transport::Timeline,
                Playthrough::PingPong,
            ),
            (
                PlaybackMode::RandomSkip,
                Transport::Timeline,
                Playthrough::Random,
            ),
            (
                PlaybackMode::BpmSync { beats: 4 },
                Transport::BpmSync { beats: 4 },
                Playthrough::Loop,
            ),
            (
                PlaybackMode::BpmBounce { beats: 8 },
                Transport::BpmSync { beats: 8 },
                Playthrough::PingPong,
            ),
            (
                PlaybackMode::BpmSkip { beats: 16 },
                Transport::BpmSync { beats: 16 },
                Playthrough::Random,
            ),
        ];
        for (mode, transport, playthrough) in cases {
            assert_eq!(mode.resolve(), (transport, playthrough), "{mode:?}");
        }
    }

    #[test]
    fn naming_a_pair_round_trips_for_all_six() {
        for mode in [
            PlaybackMode::Loop,
            PlaybackMode::Bounce,
            PlaybackMode::RandomSkip,
            PlaybackMode::BpmSync { beats: 4 },
            PlaybackMode::BpmBounce { beats: 8 },
            PlaybackMode::BpmSkip { beats: 16 },
        ] {
            let (t, p) = mode.resolve();
            assert_eq!(PlaybackMode::from_parts(t, p), Some(mode));
        }
    }

    #[test]
    fn pairs_outside_the_six_are_not_renamed_into_them() {
        // A one-shot or an externally-driven clip has no loop shape. Returning
        // the "nearest" of the six here would silently convert a one-shot into
        // a loop, which is a mode the operator did not ask for.
        for (t, p) in [
            (Transport::Timeline, Playthrough::Once),
            (Transport::Timeline, Playthrough::HoldLast),
            (Transport::BpmSync { beats: 4 }, Playthrough::Once),
            (Transport::Position, Playthrough::Loop),
            (Transport::Position, Playthrough::Random),
        ] {
            assert_eq!(PlaybackMode::from_parts(t, p), None, "{t:?}/{p:?}");
        }
    }

    #[test]
    fn only_the_bpm_modes_are_tempo_locked() {
        assert!(!PlaybackMode::Loop.is_tempo_locked());
        assert!(!PlaybackMode::Bounce.is_tempo_locked());
        assert!(!PlaybackMode::RandomSkip.is_tempo_locked());
        assert!(PlaybackMode::BpmSync { beats: 4 }.is_tempo_locked());
        assert!(PlaybackMode::BpmBounce { beats: 4 }.is_tempo_locked());
        assert!(PlaybackMode::BpmSkip { beats: 4 }.is_tempo_locked());
    }

    // ── layer-over-clip precedence ──────────────────────────────────────

    #[test]
    fn a_layer_without_an_override_follows_the_clip() {
        let l = layer(1);
        let c = clip(Transport::BpmSync { beats: 8 }, Playthrough::PingPong);
        assert_eq!(
            l.resolved_playback(Some(&c)),
            (Transport::BpmSync { beats: 8 }, Playthrough::PingPong)
        );
    }

    #[test]
    fn a_layer_override_beats_the_clips_own_setting() {
        // The whole point of the feature: set the layer to bounce and every
        // clip that lands on it bounces, whatever it was saved with.
        let mut l = layer(1);
        l.playback = Some(PlaybackMode::Bounce);
        let c = clip(Transport::BpmSync { beats: 8 }, Playthrough::Once);
        assert_eq!(
            l.resolved_playback(Some(&c)),
            (Transport::Timeline, Playthrough::PingPong)
        );
    }

    #[test]
    fn an_override_applies_to_every_clip_the_layer_could_hold() {
        let mut l = layer(1);
        l.playback = Some(PlaybackMode::BpmSkip { beats: 16 });
        let expected = (Transport::BpmSync { beats: 16 }, Playthrough::Random);
        for c in [
            clip(Transport::Timeline, Playthrough::Once),
            clip(Transport::Position, Playthrough::HoldLast),
            clip(Transport::BpmSync { beats: 2 }, Playthrough::Loop),
        ] {
            assert_eq!(l.resolved_playback(Some(&c)), expected);
        }
    }

    #[test]
    fn clearing_the_override_hands_control_back_to_the_clip() {
        // Reversible: None is not "no opinion recorded", it is "the clip
        // decides", and flipping back must restore the clip's setting exactly.
        let mut l = layer(1);
        let c = clip(Transport::Timeline, Playthrough::Once);
        l.playback = Some(PlaybackMode::Loop);
        assert_eq!(
            l.resolved_playback(Some(&c)),
            (Transport::Timeline, Playthrough::Loop)
        );
        l.playback = None;
        assert_eq!(
            l.resolved_playback(Some(&c)),
            (Transport::Timeline, Playthrough::Once)
        );
    }

    #[test]
    fn an_empty_layer_resolves_to_the_defaults() {
        let l = layer(1);
        assert_eq!(
            l.resolved_playback(None),
            (Transport::default(), Playthrough::default())
        );
    }

    #[test]
    fn an_override_on_an_empty_layer_still_applies() {
        // It must, or arming a layer before triggering anything would do
        // nothing and the first clip would play wrong.
        let mut l = layer(1);
        l.playback = Some(PlaybackMode::BpmBounce { beats: 4 });
        assert_eq!(
            l.resolved_playback(None),
            (Transport::BpmSync { beats: 4 }, Playthrough::PingPong)
        );
    }

    // ── serde ───────────────────────────────────────────────────────────

    #[test]
    fn a_fully_populated_layer_round_trips_through_json() {
        let mut l = layer(7);
        l.playback = Some(PlaybackMode::BpmBounce { beats: 8 });
        l.transform = Transform2D {
            position: Vec2 { x: 0.25, y: -0.5 },
            scale: Vec2 { x: 2.0, y: 0.5 },
            rotation_deg: 90.0,
            anchor: Vec2 { x: 0.1, y: 0.2 },
        };
        l.crossfader_group = CrossfaderGroup::B;
        l.ignore_column_trigger = true;
        l.fader_start = true;
        l.transition = LayerTransition {
            duration: Rational::new(1, 2),
            blend: BlendMode::Difference,
        };
        l.autopilot = Some(AutoPilot {
            target: AutoPilotTarget::Specific(Id::new(42)),
            after: AutoPilotTrigger::Beats(32),
            cycle: true,
        });

        let json = serde_json::to_string(&l).expect("serialise");
        let back: Layer = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(l, back);
    }

    #[test]
    fn every_autopilot_trigger_round_trips() {
        for after in [
            AutoPilotTrigger::Beats(16),
            AutoPilotTrigger::Seconds(Rational::new(30, 1)),
            AutoPilotTrigger::Loops(3),
        ] {
            let a = AutoPilot {
                target: AutoPilotTarget::Random,
                after,
                cycle: false,
            };
            let json = serde_json::to_string(&a).expect("serialise");
            assert_eq!(serde_json::from_str::<AutoPilot>(&json).unwrap(), a);
        }
    }

    #[test]
    fn a_v0_layer_still_loads() {
        // The v1 fields are all #[serde(default)], so a document saved before
        // they existed must load untouched. If this breaks, every project file
        // a user has saved stops opening.
        let v0 = r#"{
            "id": 3, "name": "Bottom", "opacity": 0.8, "blend": "multiply",
            "clip": null, "bypass": false, "solo": false
        }"#;
        let l: Layer = serde_json::from_str(v0).expect("v0 layer must still load");
        assert_eq!(l.name, "Bottom");
        assert_eq!(l.blend, BlendMode::Multiply);
        assert_eq!(
            l.playback, None,
            "absent override must mean follow the clip"
        );
        assert!(l.transform.is_identity());
        assert_eq!(l.crossfader_group, CrossfaderGroup::None);
        assert!(!l.ignore_column_trigger);
        assert!(!l.fader_start);
        assert_eq!(l.transition, LayerTransition::default());
        assert_eq!(l.autopilot, None);
    }

    #[test]
    fn a_v0_document_loads_into_a_v1_build() {
        // Whole-document form of the above: the defaults are the migration,
        // and there is deliberately no migration code.
        let v0 = r#"{
            "schemaVersion": 0,
            "meta": {"name":"old","created":"","modified":"","writtenBy":"0.0.1"},
            "composition": {"width":1920,"height":1080,
                "rate":{"num":60,"den":1},"workingSpace":"linearRgba16F"},
            "clock": {"bpm":128.0,"tempoSource":"manual",
                "phaseSource":"followTempo","quantise":"bar"},
            "layers": [{"id":1,"name":"A","opacity":1.0,"blend":"over",
                "clip":null,"bypass":false,"solo":false}],
            "clips": [], "sources": [], "modulation": []
        }"#;
        let doc: Document = serde_json::from_str(v0).expect("v0 document must load");
        assert_eq!(doc.schema_version, 0);
        assert_eq!(doc.layers[0].playback, None);
    }

    #[test]
    fn the_layer_override_is_absent_from_json_when_unset() {
        // A document that writes "playback": null for every layer is noise in
        // every diff and in every hand-edit.
        let l = layer(1);
        let json = serde_json::to_string(&l).expect("serialise");
        assert!(
            !json.contains("\"playback\":null"),
            "unset override should be omitted, got {json}"
        );
    }

    #[test]
    fn a_default_transform_is_the_identity() {
        assert!(Transform2D::default().is_identity());
        let nudged = Transform2D {
            position: Vec2 {
                x: 0.000_001,
                y: 0.0,
            },
            ..Transform2D::default()
        };
        assert!(
            !nudged.is_identity(),
            "a deliberate sub-pixel nudge must not be snapped away"
        );
    }

    #[test]
    fn a_default_transition_is_a_hard_cut() {
        // An unrequested fade on every clip trigger is worse than a cut.
        assert_eq!(LayerTransition::default().duration, Rational::new(0, 1));
    }

    #[test]
    fn unknown_fields_are_rejected() {
        // Silent field-dropping on load is how a project quietly loses data.
        let json = r#"{"schemaVersion":0,"meta":{},"bogusField":1}"#;
        assert!(serde_json::from_str::<Document>(json).is_err());
    }
}
