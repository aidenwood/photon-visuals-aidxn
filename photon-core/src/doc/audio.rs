//! The audio stage — **several live inputs at once, each with its own bands.**
//!
//! Audio is the first pane of the show, not a feature bolted to the side of it:
//! a VJ builds the visual from what the music is doing, so the document models
//! *every* source of sound in the booth rather than "the microphone".
//!
//! ## Why a list and not a single input
//!
//! One input is the degenerate case, not the normal one. A working rig has a
//! booth feed off the mixer **and** a room mic: the feed is clean and tells you
//! what the DJ is actually playing, the mic hears the crowd and the subs. Two
//! DJs changing over is two feeds. A band is a kick mic, a bass DI and an
//! overhead pair. Each of those wants its own gain, its own bands and its own
//! beat detection, and the operator wants to bind the kick drum of one and the
//! vocal of another to different parameters at the same time. A single global
//! analyser cannot express any of that, and retrofitting the identity later
//! means every saved binding becomes ambiguous.
//!
//! ## Three things live here and nowhere else
//!
//! | What | Owner | Why here |
//! |---|---|---|
//! | Which device, and how to find it again | [`AudioDeviceRef`] | survives a reboot; see the UID note below |
//! | Which channels, and how hot | [`AudioInput`] | per-input calibration, not per-binding |
//! | Which frequency ranges exist | [`AudioBandDef`] | one definition the analyser and every binding share |
//!
//! **Attack and release are deliberately *not* here.** They live with the
//! binding ([`ModSource::AudioBand`](super::ModSource)), because the core owns
//! the envelope and because the same kick band wants a 5 ms attack driving a
//! strobe and a 400 ms release driving a slow zoom. A band is a *measurement*;
//! an envelope is an *interpretation* of it, and there is one measurement and
//! many interpretations.
//!
//! ## Device identity: persist the UID **and** the name
//!
//! A device UID is the strong key and is still not enough on its own. On macOS
//! an aggregate device gets a fresh UID when it is rebuilt, and a class-compliant
//! interface can re-enumerate with a different UID after a reboot or a hub
//! change; on Windows the endpoint id moves with the driver. A name alone is
//! worse — two identical interfaces in the same rig are both "Scarlett 2i2".
//!
//! So both are persisted and matched in a fixed order by
//! [`AudioDeviceRef::match_against`], and a match that had to fall back to the
//! name is reported as such rather than silently accepted. A VJ who finds the
//! kick binding following the wrong interface needs to be *told*, not left to
//! work it out from the output.

use serde::{Deserialize, Serialize};

use super::Id;

/// Every audio input the document knows about.
///
/// Empty is a legal and common state — a project that has never had audio
/// opened. Nothing here allocates a device or starts capture; that is the
/// shell's job, driven from this list.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AudioStage {
    /// The inputs, in operator order. Several may be
    /// [`AudioInput::enabled`] simultaneously — that is the normal case.
    #[serde(default)]
    pub inputs: Vec<AudioInput>,

    /// Which input a binding that names none should follow.
    ///
    /// Exists for one specific reason: a schema-v1 document's audio bindings
    /// carry no input identity, because inputs did not exist. They have to mean
    /// *something*, and "whatever is listening" is the only honest reading.
    /// Pinning it explicitly is what an operator wants the moment there are
    /// two inputs, because otherwise plugging in a second interface silently
    /// re-points every legacy binding.
    ///
    /// Resolve it with [`AudioStage::default_input`] rather than reading this
    /// field — a stale id pointing at a deleted or disabled input must fall
    /// back, not black out half the mappings.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_input: Option<Id>,
}

impl AudioStage {
    /// The input a binding that names none follows, if there is one.
    ///
    /// Precedence, highest to lowest:
    /// 1. [`AudioStage::default_input`], when it names an input that still
    ///    exists **and** is enabled.
    /// 2. The first enabled input in operator order.
    /// 3. `None` — nothing is listening, which is a real state and is reported
    ///    as such rather than being papered over with input zero.
    #[must_use]
    pub fn default_input(&self) -> Option<&AudioInput> {
        if let Some(id) = self.default_input {
            if let Some(input) = self.inputs.iter().find(|i| i.id == id && i.enabled) {
                return Some(input);
            }
        }
        self.inputs.iter().find(|i| i.enabled)
    }

    /// One input by id, enabled or not.
    #[must_use]
    pub fn input(&self, id: Id) -> Option<&AudioInput> {
        self.inputs.iter().find(|i| i.id == id)
    }

    /// One input by id, mutably.
    pub fn input_mut(&mut self, id: Id) -> Option<&mut AudioInput> {
        self.inputs.iter_mut().find(|i| i.id == id)
    }

    /// Every enabled input, in operator order — exactly what the shell opens.
    pub fn enabled(&self) -> impl Iterator<Item = &AudioInput> {
        self.inputs.iter().filter(|i| i.enabled)
    }

    /// Resolves the input and frequency range an audio binding actually means.
    ///
    /// This is the single definition of that precedence, for the same reason
    /// [`Layer::resolved_playback`](super::Layer::resolved_playback) is: the
    /// binding stores an optional input, an optional band **and** an ad-hoc
    /// range, and exactly one of those combinations is in force at a time.
    /// Spreading the rule across the engine and the UI is how the meter and the
    /// modulation end up following different frequencies.
    ///
    /// Precedence:
    /// - `input` names an input → that one; otherwise [`Self::default_input`].
    /// - `band` names a band **on that input** → its range, threshold and gain
    ///   win outright, and `low_hz`/`high_hz` are ignored. Re-calibrating the
    ///   input therefore re-calibrates every binding on it, which is the whole
    ///   point of naming a band instead of typing numbers.
    /// - no `band`, or a `band` that no longer exists → the ad-hoc range, with
    ///   a unity gain and no threshold.
    ///
    /// Returns `None` only when there is no input at all to follow. A binding
    /// in that state is not broken — the operator has not opened audio yet —
    /// but it has nothing to measure, and saying so is better than returning a
    /// zero that reads as silence.
    #[must_use]
    pub fn resolve_band(
        &self,
        input: Option<Id>,
        band: Option<Id>,
        low_hz: f64,
        high_hz: f64,
    ) -> Option<ResolvedBand> {
        let input = match input {
            Some(id) => self.input(id)?,
            None => self.default_input()?,
        };
        let named = band.and_then(|id| input.band(id));
        Some(match named {
            Some(b) => ResolvedBand {
                input: input.id,
                band: Some(b.id),
                low_hz: b.low_hz,
                high_hz: b.high_hz,
                threshold: b.threshold,
                gain: b.gain,
            },
            None => ResolvedBand {
                input: input.id,
                band: None,
                low_hz,
                high_hz,
                threshold: 0.0,
                gain: 1.0,
            },
        })
    }
}

/// What an audio binding resolved to: one input, one frequency range, and the
/// calibration that goes with it.
///
/// Flat and `Copy` because it is what the analyser is configured from and what
/// the modulation engine interns a slot for — both of which happen on every
/// document edit and must not allocate or chase a reference back into the
/// document.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ResolvedBand {
    /// The input being measured.
    pub input: Id,
    /// The named band, when one was named. `None` is an ad-hoc range typed into
    /// the binding, which is a legitimate thing to do for a one-off.
    pub band: Option<Id>,
    /// Low edge, Hz.
    pub low_hz: f64,
    /// High edge, Hz.
    pub high_hz: f64,
    /// Below this the band reads zero — stops room noise animating everything.
    pub threshold: f64,
    /// Multiplier applied before the threshold test.
    pub gain: f64,
}

/// One live audio input.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AudioInput {
    /// Stable identity. What a binding names, and what survives a rename, a
    /// reorder and a device swap.
    pub id: Id,
    /// Operator's name for it — "Booth feed", "Room mic", "Deck B".
    ///
    /// Deliberately separate from [`AudioDeviceRef::name`]: the device is
    /// called "Scarlett 2i2 USB" and the operator calls it "the booth", and
    /// when the interface is replaced next month the operator's name should not
    /// change with it.
    pub name: String,
    /// Which hardware, and how to find it again after a reboot.
    pub device: AudioDeviceRef,
    /// Which of that device's channels are measured.
    #[serde(default)]
    pub channels: ChannelMap,
    /// Input trim in decibels, applied before analysis.
    ///
    /// Decibels and not a linear factor because this is a gain control on a
    /// console in the operator's head: +6 dB is a doubling and they know it,
    /// and a line feed versus a mic is a 40 dB difference that a 0–2 linear
    /// slider cannot reach at a useful resolution.
    #[serde(default)]
    pub gain_db: f64,
    /// Whether the shell should open and analyse this input.
    ///
    /// Several enabled at once is the normal case, not an edge case.
    #[serde(default = "yes")]
    pub enabled: bool,
    /// The frequency ranges measured on this input.
    ///
    /// Per-input rather than global because the calibration is per-input: a
    /// booth feed and a room mic do not agree on what "loud" is, and a shared
    /// threshold would either gate the mic to silence or let the feed pin
    /// everything to 1.0.
    #[serde(default)]
    pub bands: Vec<AudioBandDef>,
    /// Tempo detection on this input.
    #[serde(default)]
    pub beat: BeatDetectConfig,
}

impl AudioInput {
    /// A new input on a device, with the three default bands.
    ///
    /// Takes the ids rather than allocating them, because id allocation is the
    /// document's job and handing a type its own allocator is how two objects
    /// end up with the same id after an undo.
    #[must_use]
    pub fn new(id: Id, name: impl Into<String>, device: AudioDeviceRef, band_ids: [Id; 3]) -> Self {
        Self {
            id,
            name: name.into(),
            device,
            channels: ChannelMap::default(),
            gain_db: 0.0,
            enabled: true,
            bands: AudioBandDef::defaults(band_ids).to_vec(),
            beat: BeatDetectConfig::default(),
        }
    }

    /// One band by id.
    #[must_use]
    pub fn band(&self, id: Id) -> Option<&AudioBandDef> {
        self.bands.iter().find(|b| b.id == id)
    }

    /// Linear amplitude factor for [`AudioInput::gain_db`].
    ///
    /// Clamped to ±40 dB and defaulted on nonsense, because this number
    /// multiplies live audio: an infinity or a hand-edited `1e9` here is a
    /// full-scale output on every bound parameter at once.
    #[must_use]
    pub fn gain(&self) -> f64 {
        let db = if self.gain_db.is_finite() {
            self.gain_db.clamp(-40.0, 40.0)
        } else {
            0.0
        };
        10f64.powf(db / 20.0)
    }
}

const fn yes() -> bool {
    true
}

/// How to find a device again, and how sure we are that we did.
///
/// Both keys are persisted on purpose — see the module docs for why neither is
/// sufficient alone.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AudioDeviceRef {
    /// Platform device UID. macOS `kAudioDevicePropertyDeviceUID`, Windows
    /// endpoint id. The strong key — but not guaranteed stable across reboots,
    /// aggregate rebuilds or a change of USB port.
    pub uid: String,
    /// Device name as the OS reported it, for the fallback match.
    pub name: String,
    /// Channel count the device had when this was saved.
    ///
    /// Part of the fallback key, not decoration: it is what stops a name-only
    /// match binding a 2-channel interface's mapping onto the 8-channel one
    /// that happens to share its name.
    #[serde(default)]
    pub channel_count: u32,
}

impl AudioDeviceRef {
    /// A reference to a device the shell has just enumerated.
    #[must_use]
    pub fn new(uid: impl Into<String>, name: impl Into<String>, channel_count: u32) -> Self {
        Self {
            uid: uid.into(),
            name: name.into(),
            channel_count,
        }
    }

    /// How well a currently-present device matches this saved reference.
    ///
    /// Lives in the core rather than in each shell so macOS and Windows cannot
    /// drift into two different answers for the same rig — the operator's
    /// mental model of "did it find my interface" has to be one model.
    ///
    /// The order is fixed: UID, then name **and** channel count together. Name
    /// alone is never a match, because the one situation a fallback exists for
    /// — identical hardware in the same rig — is also the one where a name
    /// collides.
    #[must_use]
    pub fn match_against(&self, candidate: &Self) -> DeviceMatch {
        if !self.uid.is_empty() && self.uid == candidate.uid {
            DeviceMatch::Uid
        } else if !self.name.is_empty()
            && self.name == candidate.name
            && self.channel_count == candidate.channel_count
        {
            DeviceMatch::Name
        } else {
            DeviceMatch::None
        }
    }

    /// The best match among present devices, and how it was found.
    ///
    /// Returns the index into `candidates`. A UID match anywhere wins over
    /// every name match, which is why this is a scan and not a `find` — taking
    /// the first name match would pick the wrong one of two identical
    /// interfaces when the right one is sitting later in the list with the
    /// correct UID.
    #[must_use]
    pub fn best_match(&self, candidates: &[Self]) -> Option<(usize, DeviceMatch)> {
        let mut by_name = None;
        for (i, c) in candidates.iter().enumerate() {
            match self.match_against(c) {
                DeviceMatch::Uid => return Some((i, DeviceMatch::Uid)),
                DeviceMatch::Name if by_name.is_none() => by_name = Some(i),
                _ => {}
            }
        }
        by_name.map(|i| (i, DeviceMatch::Name))
    }
}

/// How a saved device reference was resolved against present hardware.
///
/// Surfaced to the operator rather than swallowed. A binding that is following
/// a device matched only by name is working, but it is working on an
/// assumption, and the one time that assumption is wrong is the one time
/// nobody can explain why the kick is driving nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceMatch {
    /// UID matched exactly. The device is the device.
    Uid,
    /// UID did not match; name and channel count did. Probably the same
    /// hardware re-enumerated — but say so.
    Name,
    /// Not present.
    None,
}

impl DeviceMatch {
    /// Whether this counts as finding the device at all.
    #[must_use]
    pub const fn is_match(self) -> bool {
        matches!(self, Self::Uid | Self::Name)
    }

    /// Whether the operator should be told the match was inferred.
    #[must_use]
    pub const fn is_inferred(self) -> bool {
        matches!(self, Self::Name)
    }
}

/// Which of a device's channels are measured.
///
/// Analysis is mono — a band level is one number — so every variant ends in a
/// single signal. Stereo is not a variant because "stereo" as an *input* to a
/// level meter only ever means "sum the two", and spelling it `Sum([0, 1])`
/// keeps one rule instead of two.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum ChannelMap {
    /// Every channel the device offers, averaged.
    ///
    /// The default, and the right one for a 2-in interface or a laptop mic: it
    /// keeps working when the device comes back with a different channel count,
    /// which a saved channel index does not.
    #[default]
    All,
    /// One specific channel, zero-based.
    Channel(u32),
    /// A named set of channels, averaged.
    ///
    /// Averaged rather than summed so that adding a channel to the set does not
    /// change how loud the input reads — a VJ adding the overhead mic to a kick
    /// feed wants to *hear* the overheads, not to have every band jump.
    Sum(Vec<u32>),
}

impl ChannelMap {
    /// The channel indices to read from a device with `available` channels.
    ///
    /// Out-of-range indices are dropped rather than clamped: clamping would
    /// silently redirect "channel 7" to channel 1 and the operator would hear
    /// the wrong thing with no indication. An empty result means *this mapping
    /// cannot be honoured on this device*, which the shell should surface.
    #[must_use]
    pub fn channels(&self, available: u32) -> Vec<u32> {
        match self {
            Self::All => (0..available).collect(),
            Self::Channel(c) => {
                if *c < available {
                    vec![*c]
                } else {
                    Vec::new()
                }
            }
            Self::Sum(list) => {
                let mut v: Vec<u32> = list.iter().copied().filter(|c| *c < available).collect();
                v.sort_unstable();
                v.dedup();
                v
            }
        }
    }
}

/// One measured frequency range on one input.
///
/// Carries the *measurement* only. The envelope that shapes it into motion
/// belongs to the binding — see the module docs.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct AudioBandDef {
    /// Stable identity. What a binding names.
    pub id: Id,
    /// Operator's name — "Kick", "Snare", "Air".
    pub name: String,
    /// Low edge, Hz.
    pub low_hz: f64,
    /// High edge, Hz.
    pub high_hz: f64,
    /// Below this the band reads zero.
    ///
    /// Not a nicety: a room mic in a loud venue has a noise floor that would
    /// otherwise keep every bound parameter permanently a third of the way up,
    /// and an operator would read that as "the modulation is broken".
    #[serde(default)]
    pub threshold: f64,
    /// Multiplier applied before the threshold test.
    #[serde(default = "unity")]
    pub gain: f64,
}

const fn unity() -> f64 {
    1.0
}

impl AudioBandDef {
    /// A band with no threshold and unity gain.
    #[must_use]
    pub fn new(id: Id, name: impl Into<String>, low_hz: f64, high_hz: f64) -> Self {
        Self {
            id,
            name: name.into(),
            low_hz,
            high_hz,
            threshold: 0.0,
            gain: 1.0,
        }
    }

    /// The three bands every VJ tool ships, as a starting point.
    ///
    /// The split points are the ones that matter musically rather than
    /// geometrically: 250 Hz is above the kick and the bass fundamental and
    /// below most of the vocal, 2 kHz is above the vocal body and into the hats
    /// and air. A logarithmic three-way split would put the boundary in the
    /// middle of the snare.
    #[must_use]
    pub fn defaults(ids: [Id; 3]) -> [Self; 3] {
        [
            Self::new(ids[0], "Low", 20.0, 250.0),
            Self::new(ids[1], "Mid", 250.0, 2_000.0),
            Self::new(ids[2], "High", 2_000.0, 16_000.0),
        ]
    }
}

/// Tempo detection on one input.
#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct BeatDetectConfig {
    /// Whether this input estimates a tempo at all.
    ///
    /// Defaults to **on**, unlike most things that cost CPU, because the
    /// estimate is cheap (see [`crate::beat`]) and because an operator asking
    /// "what BPM is this" and being told "turn detection on first" is a worse
    /// default than a few hundred multiplies a second.
    #[serde(default = "yes")]
    pub enabled: bool,

    /// The tempo the operator expects, used **only** to resolve octave
    /// ambiguity.
    ///
    /// Half-time and double-time are not detector bugs; they are genuinely
    /// correct answers to "what period repeats", and no amount of signal
    /// processing picks between 87 and 174 BPM on its own. The only thing that
    /// does is a prior, and the operator is the one who has it: a drum and bass
    /// set wants 174 and the same algorithm on the same audio should report 174,
    /// not 87.
    ///
    /// This never *forces* a tempo — it weights the candidates. A 128 BPM track
    /// still reads 128 with this left at 120.
    #[serde(default = "default_preferred_bpm")]
    pub preferred_bpm: f64,
}

fn default_preferred_bpm() -> f64 {
    120.0
}

impl Default for BeatDetectConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            preferred_bpm: default_preferred_bpm(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(uid: &str, name: &str, ch: u32) -> AudioDeviceRef {
        AudioDeviceRef::new(uid, name, ch)
    }

    fn input(id: u64, name: &str) -> AudioInput {
        AudioInput::new(
            Id::new(id),
            name,
            device(&format!("uid-{id}"), name, 2),
            [
                Id::new(id * 100 + 1),
                Id::new(id * 100 + 2),
                Id::new(id * 100 + 3),
            ],
        )
    }

    // ── several inputs at once is the normal case ───────────────────────────

    #[test]
    fn every_enabled_input_is_opened_not_just_the_first() {
        // The whole premise: a booth feed and a room mic analysed together.
        let mut stage = AudioStage::default();
        stage.inputs.push(input(1, "Booth"));
        stage.inputs.push(input(2, "Room"));
        stage.inputs.push(input(3, "Deck B"));
        assert_eq!(stage.enabled().count(), 3);

        stage.input_mut(Id::new(2)).expect("room").enabled = false;
        let names: Vec<_> = stage.enabled().map(|i| i.name.as_str()).collect();
        assert_eq!(names, ["Booth", "Deck B"]);
    }

    #[test]
    fn two_inputs_keep_separate_bands_with_the_same_frequencies() {
        // A 20-250 Hz band on the booth feed and a 20-250 Hz band on the room
        // mic are two different measurements of two different signals. If these
        // ever collapse into one, the room mic drives the booth's bindings.
        let stage = AudioStage {
            inputs: vec![input(1, "Booth"), input(2, "Room")],
            default_input: None,
        };
        let a = stage
            .resolve_band(Some(Id::new(1)), Some(Id::new(101)), 0.0, 0.0)
            .expect("booth low");
        let b = stage
            .resolve_band(Some(Id::new(2)), Some(Id::new(201)), 0.0, 0.0)
            .expect("room low");
        assert_eq!((a.low_hz, a.high_hz), (b.low_hz, b.high_hz));
        assert_ne!(a.input, b.input, "same range, different input");
    }

    // ── default-input resolution ────────────────────────────────────────────

    #[test]
    fn a_binding_naming_no_input_follows_the_pinned_default() {
        let stage = AudioStage {
            inputs: vec![input(1, "Booth"), input(2, "Room")],
            default_input: Some(Id::new(2)),
        };
        let r = stage.resolve_band(None, None, 20.0, 250.0).expect("resolved");
        assert_eq!(r.input, Id::new(2));
    }

    #[test]
    fn a_pinned_default_that_is_disabled_falls_back_rather_than_going_silent() {
        // Muting an input must not kill every legacy binding in the document.
        let mut stage = AudioStage {
            inputs: vec![input(1, "Booth"), input(2, "Room")],
            default_input: Some(Id::new(2)),
        };
        stage.input_mut(Id::new(2)).expect("room").enabled = false;
        let r = stage.resolve_band(None, None, 20.0, 250.0).expect("resolved");
        assert_eq!(r.input, Id::new(1), "falls back to the first enabled input");
    }

    #[test]
    fn a_pinned_default_pointing_at_a_deleted_input_falls_back() {
        let stage = AudioStage {
            inputs: vec![input(1, "Booth")],
            default_input: Some(Id::new(99)),
        };
        assert_eq!(
            stage.default_input().map(|i| i.id),
            Some(Id::new(1)),
            "a stale id must not black out the stage"
        );
    }

    #[test]
    fn nothing_listening_resolves_to_none_not_to_input_zero() {
        // "No audio open" is a real state. Returning a zeroed band here would
        // read downstream as a silent room, which is a different thing.
        let stage = AudioStage::default();
        assert!(stage.default_input().is_none());
        assert!(stage.resolve_band(None, None, 20.0, 250.0).is_none());
    }

    #[test]
    fn a_binding_naming_a_missing_input_does_not_drift_onto_the_default() {
        // Falling back here would be worse than failing: the operator deleted
        // an input and the binding would quietly start following a different
        // signal with no indication.
        let stage = AudioStage {
            inputs: vec![input(1, "Booth")],
            default_input: None,
        };
        assert!(stage.resolve_band(Some(Id::new(42)), None, 20.0, 250.0).is_none());
    }

    // ── band resolution precedence ──────────────────────────────────────────

    #[test]
    fn a_named_band_wins_over_the_bindings_own_range() {
        // Otherwise there are two definitions of the same frequency range and
        // re-calibrating the input would not reach the binding.
        let stage = AudioStage {
            inputs: vec![input(1, "Booth")],
            default_input: None,
        };
        let r = stage
            .resolve_band(Some(Id::new(1)), Some(Id::new(101)), 5_000.0, 9_000.0)
            .expect("resolved");
        assert_eq!((r.low_hz, r.high_hz), (20.0, 250.0));
        assert_eq!(r.band, Some(Id::new(101)));
    }

    #[test]
    fn a_band_that_no_longer_exists_falls_back_to_the_ad_hoc_range() {
        // A deleted band must leave a working binding, not a dead one — the
        // range is still right there in the document.
        let stage = AudioStage {
            inputs: vec![input(1, "Booth")],
            default_input: None,
        };
        let r = stage
            .resolve_band(Some(Id::new(1)), Some(Id::new(777)), 5_000.0, 9_000.0)
            .expect("resolved");
        assert_eq!((r.low_hz, r.high_hz), (5_000.0, 9_000.0));
        assert_eq!(r.band, None);
    }

    #[test]
    fn an_ad_hoc_range_carries_unity_gain_and_no_threshold() {
        let stage = AudioStage {
            inputs: vec![input(1, "Booth")],
            default_input: None,
        };
        let r = stage
            .resolve_band(None, None, 60.0, 80.0)
            .expect("resolved");
        assert_eq!(r.gain, 1.0);
        assert_eq!(r.threshold, 0.0);
    }

    #[test]
    fn a_named_band_carries_its_inputs_calibration() {
        let mut stage = AudioStage {
            inputs: vec![input(1, "Room")],
            default_input: None,
        };
        let band = &mut stage.inputs[0].bands[0];
        band.threshold = 0.08;
        band.gain = 2.5;
        let r = stage
            .resolve_band(None, Some(Id::new(101)), 0.0, 0.0)
            .expect("resolved");
        assert_eq!(r.threshold, 0.08);
        assert_eq!(r.gain, 2.5);
    }

    // ── device identity ─────────────────────────────────────────────────────

    #[test]
    fn a_uid_match_is_exact() {
        let saved = device("AppleUSB:14100000", "Scarlett 2i2 USB", 2);
        let present = device("AppleUSB:14100000", "Scarlett 2i2 USB", 2);
        assert_eq!(saved.match_against(&present), DeviceMatch::Uid);
        assert!(!saved.match_against(&present).is_inferred());
    }

    #[test]
    fn a_changed_uid_still_matches_by_name_and_channel_count() {
        // The reason both keys are persisted: a reboot or a different USB port
        // can hand back the same interface under a new UID.
        let saved = device("AppleUSB:14100000", "Scarlett 2i2 USB", 2);
        let present = device("AppleUSB:14200000", "Scarlett 2i2 USB", 2);
        let m = saved.match_against(&present);
        assert_eq!(m, DeviceMatch::Name);
        assert!(m.is_inferred(), "an inferred match must be reportable");
    }

    #[test]
    fn a_name_match_with_a_different_channel_count_is_not_a_match() {
        // Two devices sharing a name is exactly the case the name fallback is
        // for, so the name alone cannot be allowed to decide.
        let saved = device("uid-a", "Scarlett", 2);
        let present = device("uid-b", "Scarlett", 8);
        assert_eq!(saved.match_against(&present), DeviceMatch::None);
    }

    #[test]
    fn a_uid_match_later_in_the_list_beats_a_name_match_earlier_in_it() {
        // Two identical interfaces in one rig. Taking the first name match
        // would pick the wrong one while the right one sits two slots down.
        let saved = device("uid-right", "Scarlett 2i2 USB", 2);
        let present = [
            device("uid-other", "Scarlett 2i2 USB", 2),
            device("uid-unrelated", "Built-in Microphone", 1),
            device("uid-right", "Scarlett 2i2 USB", 2),
        ];
        assert_eq!(saved.best_match(&present), Some((2, DeviceMatch::Uid)));
    }

    #[test]
    fn an_absent_device_reports_no_match_rather_than_guessing() {
        let saved = device("uid-a", "Scarlett", 2);
        let present = [device("uid-b", "Built-in Microphone", 1)];
        assert_eq!(saved.best_match(&present), None);
    }

    #[test]
    fn an_empty_uid_never_matches_another_empty_uid() {
        // A document written before UIDs were captured, or a shell that could
        // not read one. Matching two blanks would pair arbitrary devices.
        let saved = device("", "Scarlett", 2);
        let present = device("", "Totally Different", 2);
        assert_eq!(saved.match_against(&present), DeviceMatch::None);
    }

    // ── channel mapping ─────────────────────────────────────────────────────

    #[test]
    fn all_follows_the_device_rather_than_a_saved_count() {
        assert_eq!(ChannelMap::All.channels(4), vec![0, 1, 2, 3]);
        assert_eq!(ChannelMap::All.channels(1), vec![0]);
    }

    #[test]
    fn an_out_of_range_channel_is_dropped_not_clamped() {
        // Clamping would silently feed channel 0 to a mapping that says 7.
        assert!(ChannelMap::Channel(7).channels(2).is_empty());
        assert_eq!(ChannelMap::Sum(vec![0, 7, 1]).channels(2), vec![0, 1]);
    }

    #[test]
    fn a_duplicated_channel_is_counted_once() {
        assert_eq!(ChannelMap::Sum(vec![1, 1, 1]).channels(4), vec![1]);
    }

    // ── gain ────────────────────────────────────────────────────────────────

    #[test]
    fn gain_db_is_decibels_and_clamped() {
        let mut i = input(1, "Booth");
        assert!((i.gain() - 1.0).abs() < 1e-12);
        i.gain_db = 6.0206;
        assert!((i.gain() - 2.0).abs() < 1e-4, "+6 dB is a doubling");
        i.gain_db = 1.0e9;
        assert!(i.gain() <= 100.0, "a hand-edited gain cannot pin the show");
        i.gain_db = f64::NAN;
        assert_eq!(i.gain(), 1.0, "nonsense is unity, never NaN");
    }

    // ── serde ───────────────────────────────────────────────────────────────

    #[test]
    fn the_stage_round_trips_through_json() {
        let mut stage = AudioStage {
            inputs: vec![input(1, "Booth"), input(2, "Room")],
            default_input: Some(Id::new(1)),
        };
        stage.inputs[1].channels = ChannelMap::Sum(vec![0, 1]);
        stage.inputs[1].gain_db = -3.0;
        stage.inputs[1].beat.preferred_bpm = 174.0;
        let json = serde_json::to_string(&stage).expect("serialise");
        let back: AudioStage = serde_json::from_str(&json).expect("deserialise");
        assert_eq!(stage, back);
    }

    #[test]
    fn a_minimal_input_loads_with_working_defaults() {
        // The fields a hand-written or older document can legitimately omit.
        let json = r#"{"id":1,"name":"Booth",
            "device":{"uid":"u","name":"n"}}"#;
        let i: AudioInput = serde_json::from_str(json).expect("minimal input must load");
        assert!(i.enabled, "an input with no `enabled` must be on");
        assert_eq!(i.channels, ChannelMap::All);
        assert_eq!(i.gain_db, 0.0);
        assert!(i.bands.is_empty());
        assert!(i.beat.enabled);
        assert_eq!(i.beat.preferred_bpm, 120.0);
    }

    #[test]
    fn a_band_without_a_gain_is_unity_not_zero() {
        // A defaulted 0.0 gain would make every band on a hand-edited input
        // read silence, which looks exactly like a dead input.
        let json = r#"{"id":1,"name":"Kick","lowHz":40,"highHz":120}"#;
        let b: AudioBandDef = serde_json::from_str(json).expect("minimal band");
        assert_eq!(b.gain, 1.0);
        assert_eq!(b.threshold, 0.0);
    }
}
