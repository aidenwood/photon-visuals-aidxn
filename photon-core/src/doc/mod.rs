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
pub const SCHEMA_VERSION: u32 = 0;

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
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Layer {
    /// Stable identity.
    pub id: Id,
    /// Display name.
    pub name: String,
    /// 0.0–1.0.
    pub opacity: f64,
    /// How this layer combines with the accumulated result beneath it.
    pub blend: BlendMode,
    /// Currently active clip, if any.
    pub clip: Option<Id>,
    /// Excluded from the composite.
    pub bypass: bool,
    /// Soloed; when any layer is soloed, non-soloed layers are excluded.
    pub solo: bool,
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

    #[test]
    fn unknown_fields_are_rejected() {
        // Silent field-dropping on load is how a project quietly loses data.
        let json = r#"{"schemaVersion":0,"meta":{},"bogusField":1}"#;
        assert!(serde_json::from_str::<Document>(json).is_err());
    }
}
