//! Control mapping and learn mode.
//!
//! Binds physical controls — MIDI faders, pads, OSC addresses, keys — to
//! parameters and actions. One map, one router, every surface.
//!
//! ## Why this is in the portable core
//!
//! Mapping is pure logic: a source arrives, a target moves. Putting it in the
//! shell would mean writing it twice and having the two drift, which is exactly
//! how a Windows port becomes a rewrite. The shells own *transport* — CoreMIDI,
//! WinMM, a UDP socket — and hand the decoded event here.
//!
//! ## What experience says this has to get right
//!
//! **Learn must not latch onto noise.** A cheap fader idles by oscillating a
//! value or two. Arm a parameter next to one and it binds to the wrong control
//! before the operator has touched anything — and they then have to find and
//! undo a binding they never made. So a continuous control must *move*, by a
//! real amount, before it counts. See [`LEARN_MOVEMENT_THRESHOLD`].
//!
//! **Rebinding must say what it displaced.** Control surfaces run out of pads
//! long before a show runs out of parameters. Silently stealing a pad from
//! whatever had it is how a blackout button stops working halfway through a
//! set, with nothing on screen to explain it. [`Routed::Learned`] carries the
//! displaced assignment so the UI can say so.
//!
//! **A fader that is out of sync must not jump.** Switch banks and the physical
//! fader is at 0 while the layer sits at 0.8. Touch it and the layer slams to
//! black. [`Pickup`] holds the parameter until the fader passes through the
//! value it already has — standard on every hardware desk, and the difference
//! between a mapping that is usable live and one that is not.
//!
//! **Note-on with velocity 0 is a note-off.** Written into the MIDI spec and
//! emitted by a great deal of real hardware. A mapper that misses it leaves
//! pads latched on.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::modulation::{ParamId, ParameterRegistry};

/// How far a continuous control must move during learn before it binds,
/// as a fraction of full travel.
///
/// Roughly three steps of a 7-bit MIDI fader. Below this is noise; above it is
/// a hand. Set too low and a jittery desk binds itself to whatever is armed;
/// set too high and a short knob throw never registers.
pub const LEARN_MOVEMENT_THRESHOLD: f64 = 0.02;

// ── sources ─────────────────────────────────────────────────────────────────

/// A physical control, as identified on the wire.
///
/// Ordered and hashable so it can key the map. Deliberately *not* the raw MIDI
/// bytes: channel and number are what an operator sees printed on the surface,
/// and what a saved map has to survive a reconnect with.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ControlSource {
    /// Continuous controller. Channel 0–15, controller number 0–127.
    MidiCc {
        /// MIDI channel, 0-based.
        channel: u8,
        /// Controller number.
        cc: u8,
    },
    /// A pad or key on a MIDI instrument.
    MidiNote {
        /// MIDI channel, 0-based.
        channel: u8,
        /// Note number.
        note: u8,
    },
    /// The pitch wheel. 14-bit, and the only MIDI control that is.
    MidiPitchBend {
        /// MIDI channel, 0-based.
        channel: u8,
    },
    /// An OSC address pattern, matched exactly.
    Osc {
        /// Full address, e.g. `/photon/layer/1/opacity`.
        address: String,
    },
    /// A computer keyboard key, identified by the shell's key code string.
    Key {
        /// Platform-independent key identifier, e.g. `"KeyQ"`.
        code: String,
    },
}

impl ControlSource {
    /// Whether this source is continuous, and so subject to movement
    /// thresholds and pickup.
    #[must_use]
    pub const fn is_continuous(&self) -> bool {
        matches!(self, Self::MidiCc { .. } | Self::MidiPitchBend { .. })
    }

    /// A short label for the UI, e.g. `CC 7 ch 1`.
    ///
    /// Channels are shown **1-based** because that is what is printed on the
    /// hardware, even though the wire is 0-based.
    #[must_use]
    pub fn label(&self) -> String {
        match self {
            Self::MidiCc { channel, cc } => format!("CC {cc} ch {}", channel + 1),
            Self::MidiNote { channel, note } => format!("Note {note} ch {}", channel + 1),
            Self::MidiPitchBend { channel } => format!("Pitch ch {}", channel + 1),
            Self::Osc { address } => address.clone(),
            Self::Key { code } => format!("Key {code}"),
        }
    }
}

/// An inbound value, in whatever resolution the transport carries.
///
/// Normalisation happens here rather than in each shell, so a 7-bit fader and
/// a 14-bit wheel land on the same scale and the map does not care which.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "value")]
pub enum ControlValue {
    /// 7-bit MIDI, 0–127.
    Midi7(u8),
    /// 14-bit MIDI pitch bend, 0–16383.
    Midi14(u16),
    /// Already normalised, 0–1. OSC and anything from a remote.
    Unit(f64),
    /// A press or a release.
    Gate(bool),
}

impl ControlValue {
    /// A note-on, applying the spec's velocity-0 rule.
    ///
    /// A note-on with velocity 0 **is** a note-off. Hardware does this
    /// constantly — it saves a status byte under running status — and a mapper
    /// that misses it leaves every pad latched on.
    #[must_use]
    pub const fn from_note_on(velocity: u8) -> Self {
        Self::Gate(velocity > 0)
    }

    /// Normalised 0–1.
    #[must_use]
    pub fn unit(self) -> f64 {
        match self {
            Self::Midi7(v) => f64::from(v.min(127)) / 127.0,
            Self::Midi14(v) => f64::from(v.min(16383)) / 16383.0,
            Self::Unit(v) => {
                if v.is_nan() {
                    0.0
                } else {
                    v.clamp(0.0, 1.0)
                }
            }
            Self::Gate(on) => {
                if on {
                    1.0
                } else {
                    0.0
                }
            }
        }
    }

    /// Whether this reads as a press.
    #[must_use]
    pub fn is_press(self) -> bool {
        match self {
            Self::Gate(on) => on,
            other => other.unit() > 0.5,
        }
    }
}

// ── targets ─────────────────────────────────────────────────────────────────

/// Something a control can do that is not a parameter.
///
/// Kept separate from parameters because these are *edges*, not values: they
/// happen once on press and have no position to read back.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "action")]
pub enum Action {
    /// Fire one clip on one layer.
    TriggerCell {
        /// Layer index.
        layer: u32,
        /// Column index.
        column: u32,
    },
    /// Fire a whole column — the primary performance gesture.
    TriggerColumn {
        /// Column index.
        column: u32,
    },
    /// Stop a layer.
    ClearLayer {
        /// Layer index.
        layer: u32,
    },
    /// Advance the cue list.
    CueGo,
    /// Kill output.
    Blackout,
    /// Contribute one tap to the tempo estimate.
    TapTempo,
    /// Resync the beat grid to now.
    Resync,
}

/// What a control is bound to.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Target {
    /// A registered parameter, named by path.
    ///
    /// Stored as a path, not a [`ParamId`], because a map outlives any one
    /// session: slots are assigned at startup in registration order, paths are
    /// stable across versions.
    Parameter {
        /// Registry path, e.g. `layer.1.opacity`.
        path: String,
    },
    /// A one-shot action.
    Action(Action),
}

impl Target {
    /// Convenience constructor for a parameter target.
    #[must_use]
    pub fn parameter(path: impl Into<String>) -> Self {
        Self::Parameter { path: path.into() }
    }
}

// ── assignment shaping ──────────────────────────────────────────────────────

/// How a gate-like control behaves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Behaviour {
    /// Held: on while pressed, off on release. The default for a pad bound to
    /// a parameter, because it is the one behaviour that cannot get stuck.
    #[default]
    Momentary,
    /// Press flips between the ends of the range; release does nothing.
    Toggle,
    /// Press fires once; release does nothing. Required for actions.
    Trigger,
}

/// Response shape applied to a continuous control.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Curve {
    /// Straight through.
    #[default]
    Linear,
    /// Fine control at the bottom of the throw — what a brightness or volume
    /// fader wants, because perception is not linear.
    Exponential,
    /// Fine control at the top.
    Logarithmic,
    /// Eased at both ends, steep through the middle. Good for crossfades.
    SCurve,
}

impl Curve {
    /// Shapes a 0–1 position. Endpoints are exact for every curve, so a fader
    /// at the top always means fully on.
    #[must_use]
    pub fn apply(self, t: f64) -> f64 {
        let t = if t.is_nan() { 0.0 } else { t.clamp(0.0, 1.0) };
        match self {
            Self::Linear => t,
            Self::Exponential => t * t,
            Self::Logarithmic => t.sqrt(),
            Self::SCurve => t * t * (3.0 - 2.0 * t),
        }
    }
}

/// One binding: a source, a target, and the shaping between them.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Assignment {
    /// What this control drives.
    pub target: Target,
    /// Gate behaviour. Ignored by continuous controls.
    #[serde(default)]
    pub behaviour: Behaviour,
    /// Where full travel starts, 0–1 into the parameter's own sweep.
    #[serde(default)]
    pub from: f64,
    /// Where full travel ends. **Less than `from` inverts the control**, which
    /// is how a fader is reversed without a separate flag.
    #[serde(default = "one")]
    pub to: f64,
    /// Response shape.
    #[serde(default)]
    pub curve: Curve,
    /// Hold the parameter until the control passes through its current value.
    ///
    /// On by default for continuous controls: a jump on bank-switch is the
    /// single most destructive thing a mapping can do live.
    #[serde(default = "yes")]
    pub pickup: bool,
}

const fn one() -> f64 {
    1.0
}
const fn yes() -> bool {
    true
}

impl Assignment {
    /// A plain full-range binding.
    #[must_use]
    pub fn new(target: Target) -> Self {
        let behaviour = if matches!(target, Target::Action(_)) {
            // An action has no position to hold, so momentary is meaningless:
            // it would fire on press and then fire *again* on release.
            Behaviour::Trigger
        } else {
            Behaviour::Momentary
        };
        Self {
            target,
            behaviour,
            from: 0.0,
            to: 1.0,
            curve: Curve::Linear,
            pickup: true,
        }
    }

    /// Sets the travel range. Reversed endpoints invert the control.
    #[must_use]
    pub fn ranged(mut self, from: f64, to: f64) -> Self {
        self.from = sane(from);
        self.to = sane(to);
        self
    }

    /// Sets the response curve.
    #[must_use]
    pub const fn shaped(mut self, curve: Curve) -> Self {
        self.curve = curve;
        self
    }

    /// Sets the gate behaviour.
    #[must_use]
    pub const fn behaving(mut self, behaviour: Behaviour) -> Self {
        self.behaviour = behaviour;
        self
    }

    /// Turns pickup off — for a control that is already in sync, like a remote
    /// UI fader that renders the real value.
    #[must_use]
    pub const fn without_pickup(mut self) -> Self {
        self.pickup = false;
        self
    }

    /// Maps raw control travel to a position in the parameter's sweep.
    #[must_use]
    pub fn position(&self, unit: f64) -> f64 {
        let shaped = self.curve.apply(unit);
        (self.from + (self.to - self.from) * shaped).clamp(0.0, 1.0)
    }

    /// Whether this assignment inverts its control.
    #[must_use]
    pub fn is_inverted(&self) -> bool {
        self.to < self.from
    }
}

fn sane(v: f64) -> f64 {
    if v.is_nan() {
        0.0
    } else {
        v.clamp(0.0, 1.0)
    }
}

// ── the map ─────────────────────────────────────────────────────────────────

/// The persisted set of bindings.
///
/// Serialises as a list rather than a JSON object because the key is a struct.
/// A list also keeps the file readable and diffable, which matters when a map
/// is the thing an operator carries between shows.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlMap {
    /// Bindings, kept sorted by source for stable output.
    entries: Vec<MapEntry>,
}

/// One row of a [`ControlMap`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MapEntry {
    /// The physical control.
    pub source: ControlSource,
    /// What it does.
    pub assignment: Assignment,
}

impl ControlMap {
    /// An empty map.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Binds a source, replacing anything already on it.
    ///
    /// Returns the displaced assignment, which the caller is expected to
    /// **show the operator**. Silently stealing a pad is how a blackout button
    /// stops working mid-set with nothing on screen to explain it.
    pub fn bind(&mut self, source: ControlSource, assignment: Assignment) -> Option<Assignment> {
        match self.entries.binary_search_by(|e| e.source.cmp(&source)) {
            Ok(i) => Some(std::mem::replace(&mut self.entries[i].assignment, assignment)),
            Err(i) => {
                self.entries.insert(i, MapEntry { source, assignment });
                None
            }
        }
    }

    /// Removes a binding.
    pub fn unbind(&mut self, source: &ControlSource) -> Option<Assignment> {
        match self.entries.binary_search_by(|e| e.source.cmp(source)) {
            Ok(i) => Some(self.entries.remove(i).assignment),
            Err(_) => None,
        }
    }

    /// The assignment on a source.
    #[must_use]
    pub fn get(&self, source: &ControlSource) -> Option<&Assignment> {
        self.entries
            .binary_search_by(|e| e.source.cmp(source))
            .ok()
            .map(|i| &self.entries[i].assignment)
    }

    /// Mutable access, for editing a range or curve in place.
    pub fn get_mut(&mut self, source: &ControlSource) -> Option<&mut Assignment> {
        self.entries
            .binary_search_by(|e| e.source.cmp(source))
            .ok()
            .map(|i| &mut self.entries[i].assignment)
    }

    /// Every binding, in source order.
    pub fn iter(&self) -> impl Iterator<Item = &MapEntry> {
        self.entries.iter()
    }

    /// Number of bindings.
    #[must_use]
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether nothing is bound.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Drops every binding.
    pub fn clear(&mut self) {
        self.entries.clear();
    }

    /// Sources bound to a given target.
    ///
    /// More than one is legal and often wanted — a fader on the desk and a
    /// fader on a phone. It is still worth surfacing, because it is also what
    /// an accidental double-assignment looks like.
    #[must_use]
    pub fn sources_for(&self, target: &Target) -> Vec<&ControlSource> {
        self.entries
            .iter()
            .filter(|e| &e.assignment.target == target)
            .map(|e| &e.source)
            .collect()
    }

    /// Targets driven by more than one control, with their sources.
    ///
    /// For a "check my map" view before a show, where finding this out early is
    /// the entire point.
    #[must_use]
    pub fn duplicated_targets(&self) -> Vec<(&Target, Vec<&ControlSource>)> {
        let mut by_target: BTreeMap<&Target, Vec<&ControlSource>> = BTreeMap::new();
        for e in &self.entries {
            by_target.entry(&e.assignment.target).or_default().push(&e.source);
        }
        by_target.into_iter().filter(|(_, v)| v.len() > 1).collect()
    }

    /// Parameter targets that nothing in `registry` provides.
    ///
    /// A map saved against one document and loaded against another will have
    /// these, and the honest thing is to list them rather than let the controls
    /// quietly do nothing.
    #[must_use]
    pub fn unresolved(&self, registry: &ParameterRegistry) -> Vec<&str> {
        self.entries
            .iter()
            .filter_map(|e| match &e.assignment.target {
                Target::Parameter { path } if registry.resolve(path).is_none() => {
                    Some(path.as_str())
                }
                _ => None,
            })
            .collect()
    }
}

// ── routing ─────────────────────────────────────────────────────────────────

/// What happened to an inbound control event.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind", content = "detail")]
pub enum Routed {
    /// Learn captured the control.
    Learned {
        /// What it was bound to.
        target: Target,
        /// What this control used to do, if anything. **Show this.**
        displaced: Option<Assignment>,
    },
    /// Learn is armed but this control has not moved enough to count yet.
    Learning,
    /// A parameter should move to `position` within its own sweep, 0–1.
    Parameter {
        /// Registry path.
        path: String,
        /// Position into the parameter's start/stop sweep.
        position: f64,
    },
    /// An action should fire.
    Action(Action),
    /// Nothing happened, and why.
    Ignored(Ignored),
}

/// Why an inbound event produced nothing.
///
/// Routing silently is indistinguishable from a broken cable. Every dead end
/// has a reason attached so a monitor view can show it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Ignored {
    /// Nothing is bound to this control.
    Unbound,
    /// A release on a control that only acts on press.
    Release,
    /// Pickup is engaged: the control has not yet passed through the
    /// parameter's current value.
    AwaitingPickup,
}

/// Per-source state that is **not** part of the saved map.
#[derive(Debug, Clone, Default)]
struct SourceRuntime {
    /// Last normalised value seen, for movement detection and pickup.
    last: Option<f64>,
    /// First value seen since learn was armed.
    armed_at: Option<f64>,
    /// Latch state for [`Behaviour::Toggle`].
    toggled: bool,
    /// Pickup has been satisfied and the control is live.
    picked_up: bool,
}

/// Learn-mode state.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum LearnState {
    /// Controls route normally.
    #[default]
    Idle,
    /// The next control that moves binds to `target`.
    Armed {
        /// What the next control will drive.
        target: Target,
        /// Shaping to give the new binding, so the UI can arm "inverted" or
        /// "toggle" before the operator touches anything.
        template: Assignment,
    },
}

/// Routes inbound controls through a [`ControlMap`].
///
/// Holds the live state a map must not: pickup, toggles, what a fader last
/// read. That split is deliberate — saving a show must not save the fact that
/// a pad happened to be latched when the file was written.
#[derive(Debug, Clone, Default)]
pub struct ControlRouter {
    /// The persisted bindings.
    pub map: ControlMap,
    learn: LearnState,
    runtime: BTreeMap<ControlSource, SourceRuntime>,
}

impl ControlRouter {
    /// A router over an empty map.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// A router over an existing map.
    #[must_use]
    pub fn with_map(map: ControlMap) -> Self {
        Self {
            map,
            learn: LearnState::Idle,
            runtime: BTreeMap::new(),
        }
    }

    /// Current learn state, for the UI.
    #[must_use]
    pub fn learn_state(&self) -> &LearnState {
        &self.learn
    }

    /// Whether learn is waiting for a control.
    #[must_use]
    pub fn is_learning(&self) -> bool {
        matches!(self.learn, LearnState::Armed { .. })
    }

    /// Arms learn for a target. The next control that moves binds to it.
    pub fn arm(&mut self, target: Target) {
        self.arm_with(target.clone(), Assignment::new(target));
    }

    /// Arms learn with a prepared assignment, so range, curve and behaviour can
    /// be chosen before the control is touched.
    pub fn arm_with(&mut self, target: Target, template: Assignment) {
        self.learn = LearnState::Armed { target, template };
        // Forget where every continuous control was sitting, so movement is
        // measured from the moment of arming rather than from whenever that
        // control was last touched.
        for r in self.runtime.values_mut() {
            r.armed_at = None;
        }
    }

    /// Cancels learn without binding anything.
    pub fn disarm(&mut self) {
        self.learn = LearnState::Idle;
    }

    /// Feeds one decoded control event.
    ///
    /// `current` reads the target parameter's present position, 0–1, and is
    /// what pickup compares against. Return `None` for a parameter whose value
    /// is unknown and pickup is skipped — an unknown value cannot jump.
    pub fn observe(
        &mut self,
        source: &ControlSource,
        value: ControlValue,
        current: impl Fn(&Target) -> Option<f64>,
    ) -> Routed {
        let unit = value.unit();

        if let LearnState::Armed { target, template } = self.learn.clone() {
            return self.try_learn(source, value, unit, target, template);
        }

        let Some(assignment) = self.map.get(source).cloned() else {
            self.runtime.entry(source.clone()).or_default().last = Some(unit);
            return Routed::Ignored(Ignored::Unbound);
        };

        let routed = self.route(source, &assignment, value, unit, &current);
        self.runtime.entry(source.clone()).or_default().last = Some(unit);
        routed
    }

    fn try_learn(
        &mut self,
        source: &ControlSource,
        value: ControlValue,
        unit: f64,
        target: Target,
        template: Assignment,
    ) -> Routed {
        let runtime = self.runtime.entry(source.clone()).or_default();

        if source.is_continuous() {
            // A continuous control has to move. The first value since arming is
            // the reference; anything within the threshold of it is idle noise,
            // not a hand on a fader.
            match runtime.armed_at {
                None => {
                    runtime.armed_at = Some(unit);
                    runtime.last = Some(unit);
                    return Routed::Learning;
                }
                Some(start) if (unit - start).abs() < LEARN_MOVEMENT_THRESHOLD => {
                    runtime.last = Some(unit);
                    return Routed::Learning;
                }
                Some(_) => {}
            }
        } else if !value.is_press() {
            // Binding on release would capture a pad the operator was already
            // holding when they armed, rather than the one they then pressed.
            runtime.last = Some(unit);
            return Routed::Learning;
        }

        runtime.last = Some(unit);
        runtime.armed_at = None;
        // A control that has just been reassigned must re-earn pickup: it is by
        // definition out of sync with its new target.
        runtime.picked_up = false;
        runtime.toggled = false;

        let mut assignment = template;
        assignment.target = target.clone();
        let displaced = self.map.bind(source.clone(), assignment);
        self.learn = LearnState::Idle;
        Routed::Learned { target, displaced }
    }

    fn route(
        &mut self,
        source: &ControlSource,
        assignment: &Assignment,
        value: ControlValue,
        unit: f64,
        current: &impl Fn(&Target) -> Option<f64>,
    ) -> Routed {
        // Actions are edges. Fire on press, never on release.
        if let Target::Action(action) = &assignment.target {
            return if value.is_press() {
                Routed::Action(action.clone())
            } else {
                Routed::Ignored(Ignored::Release)
            };
        }

        let Target::Parameter { path } = &assignment.target else {
            unreachable!("target is either a parameter or an action")
        };

        if source.is_continuous() {
            if assignment.pickup {
                let runtime = self.runtime.entry(source.clone()).or_default();
                if !runtime.picked_up {
                    let target_position = current(&assignment.target);
                    match (target_position, runtime.last) {
                        // Nothing to be out of sync with.
                        (None, _) => runtime.picked_up = true,
                        (Some(target_position), Some(previous)) => {
                            let now = assignment.position(unit);
                            let before = assignment.position(previous);
                            // Crossed, or landed exactly on it.
                            let crossed = (before - target_position)
                                * (now - target_position)
                                <= 0.0;
                            if crossed {
                                runtime.picked_up = true;
                            } else {
                                runtime.last = Some(unit);
                                return Routed::Ignored(Ignored::AwaitingPickup);
                            }
                        }
                        // First event since a reset: record and wait, so the
                        // very first move is measured rather than obeyed.
                        (Some(_), None) => {
                            runtime.last = Some(unit);
                            return Routed::Ignored(Ignored::AwaitingPickup);
                        }
                    }
                }
            }
            return Routed::Parameter {
                path: path.clone(),
                position: assignment.position(unit),
            };
        }

        match assignment.behaviour {
            Behaviour::Momentary => Routed::Parameter {
                path: path.clone(),
                position: assignment.position(unit),
            },
            Behaviour::Toggle => {
                if !value.is_press() {
                    return Routed::Ignored(Ignored::Release);
                }
                let runtime = self.runtime.entry(source.clone()).or_default();
                runtime.toggled = !runtime.toggled;
                let unit = if runtime.toggled { 1.0 } else { 0.0 };
                Routed::Parameter {
                    path: path.clone(),
                    position: assignment.position(unit),
                }
            }
            Behaviour::Trigger => {
                if value.is_press() {
                    Routed::Parameter {
                        path: path.clone(),
                        position: assignment.position(1.0),
                    }
                } else {
                    Routed::Ignored(Ignored::Release)
                }
            }
        }
    }

    /// Resolves a routed parameter against a registry and returns the value to
    /// apply.
    ///
    /// Returns `None` for a path nothing registered — a map from another
    /// document. The control does nothing, which is correct, and
    /// [`ControlMap::unresolved`] is how the operator finds out why.
    #[must_use]
    pub fn resolve(
        registry: &ParameterRegistry,
        path: &str,
        position: f64,
    ) -> Option<(ParamId, f64)> {
        let id = registry.resolve(path)?;
        let spec = registry.spec(id)?;
        Some((id, spec.value_at(position)))
    }

    /// Forces a control to re-earn pickup — after a bank switch, a page change,
    /// or loading a document.
    ///
    /// Without this, a fader that was live before the switch stays live and
    /// jumps the new target on first touch, which is the exact failure pickup
    /// exists to prevent.
    pub fn reset_pickup(&mut self) {
        for r in self.runtime.values_mut() {
            r.picked_up = false;
            r.last = None;
        }
    }

    /// Sets a toggle's latch from authoritative state.
    ///
    /// Two pads bound to one target each hold their own latch and will disagree
    /// after the other is pressed. The engine knows the truth; this tells the
    /// router, so the next press flips from the real state rather than from a
    /// stale one.
    pub fn sync_toggle(&mut self, source: &ControlSource, on: bool) {
        self.runtime.entry(source.clone()).or_default().toggled = on;
    }

    /// What to push back to lit surfaces.
    ///
    /// `value_of` reads the present 0–1 position of a target. Controls bound to
    /// actions report 0 — an action has no state, and lighting its pad
    /// permanently would be a lie.
    #[must_use]
    pub fn feedback(&self, value_of: impl Fn(&Target) -> Option<f64>) -> Vec<(ControlSource, f64)> {
        self.map
            .iter()
            .map(|e| {
                let v = match &e.assignment.target {
                    Target::Action(_) => 0.0,
                    t => value_of(t).unwrap_or(0.0),
                };
                (e.source.clone(), v.clamp(0.0, 1.0))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::modulation::{Bounds, ParamSpec};

    fn cc(n: u8) -> ControlSource {
        ControlSource::MidiCc { channel: 0, cc: n }
    }
    fn note(n: u8) -> ControlSource {
        ControlSource::MidiNote {
            channel: 0,
            note: n,
        }
    }
    fn nothing(_: &Target) -> Option<f64> {
        None
    }

    // ── learn ───────────────────────────────────────────────────────────────

    #[test]
    fn learn_ignores_a_jittering_fader_and_binds_the_one_that_moves() {
        // The failure this prevents: arm a parameter next to a cheap desk and a
        // noisy fader binds itself before the operator touches anything.
        let mut r = ControlRouter::new();
        r.arm(Target::parameter("layer.1.opacity"));

        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(64), nothing), Routed::Learning);
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(65), nothing), Routed::Learning);
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(63), nothing), Routed::Learning);
        assert!(r.is_learning(), "noise must not complete a learn");

        // A hand on a different fader.
        let out = r.observe(&cc(21), ControlValue::Midi7(0), nothing);
        assert_eq!(out, Routed::Learning, "first value is the reference");
        let out = r.observe(&cc(21), ControlValue::Midi7(90), nothing);
        assert!(matches!(out, Routed::Learned { .. }));
        assert!(r.map.get(&cc(21)).is_some());
        assert!(r.map.get(&cc(7)).is_none());
    }

    #[test]
    fn a_pad_binds_on_press_not_on_release() {
        // Binding on release would capture a pad already held when arming.
        let mut r = ControlRouter::new();
        r.arm(Target::Action(Action::Blackout));
        assert_eq!(r.observe(&note(36), ControlValue::Gate(false), nothing), Routed::Learning);
        assert!(matches!(
            r.observe(&note(36), ControlValue::Gate(true), nothing),
            Routed::Learned { .. }
        ));
    }

    #[test]
    fn rebinding_reports_what_it_displaced() {
        // A pad silently stolen from blackout is how a show loses its panic
        // button with nothing on screen to explain it.
        let mut r = ControlRouter::new();
        r.map.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));

        r.arm(Target::Action(Action::CueGo));
        let out = r.observe(&note(36), ControlValue::Gate(true), nothing);
        match out {
            Routed::Learned { displaced, .. } => {
                let displaced = displaced.expect("must report the displaced binding");
                assert_eq!(displaced.target, Target::Action(Action::Blackout));
            }
            other => panic!("expected a learn, got {other:?}"),
        }
    }

    #[test]
    fn arming_measures_movement_from_the_moment_of_arming() {
        // A fader touched earlier in the session must not count as "moved"
        // just because its old value differs from where it sits now.
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("a")));
        r.observe(&cc(7), ControlValue::Midi7(0), nothing);
        r.observe(&cc(7), ControlValue::Midi7(127), nothing);

        r.arm(Target::parameter("b"));
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(127), nothing), Routed::Learning);
        assert!(r.is_learning());
    }

    #[test]
    fn disarm_leaves_the_map_alone() {
        let mut r = ControlRouter::new();
        r.arm(Target::parameter("a"));
        r.disarm();
        assert!(!r.is_learning());
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(100), nothing),
                   Routed::Ignored(Ignored::Unbound));
        assert!(r.map.is_empty());
    }

    #[test]
    fn a_learned_control_must_re_earn_pickup() {
        // It was just pointed at something new, so it is out of sync by
        // definition.
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("a")));
        // Pick up on "a".
        r.observe(&cc(7), ControlValue::Midi7(0), |_| Some(0.0));
        r.observe(&cc(7), ControlValue::Midi7(10), |_| Some(0.0));

        r.arm(Target::parameter("b"));
        r.observe(&cc(7), ControlValue::Midi7(10), nothing);
        assert!(matches!(
            r.observe(&cc(7), ControlValue::Midi7(120), nothing),
            Routed::Learned { .. }
        ));
        // "b" sits at 1.0, the fader is near the top but not there.
        let out = r.observe(&cc(7), ControlValue::Midi7(100), |_| Some(1.0));
        assert_eq!(out, Routed::Ignored(Ignored::AwaitingPickup));
    }

    // ── gates ───────────────────────────────────────────────────────────────

    #[test]
    fn note_on_with_velocity_zero_is_a_release() {
        // In the spec, emitted constantly by real hardware, and a mapper that
        // misses it leaves pads latched on.
        assert_eq!(ControlValue::from_note_on(0), ControlValue::Gate(false));
        assert_eq!(ControlValue::from_note_on(1), ControlValue::Gate(true));
        assert!(!ControlValue::from_note_on(0).is_press());
    }

    #[test]
    fn momentary_is_on_while_held() {
        let mut r = ControlRouter::new();
        r.map.bind(note(36), Assignment::new(Target::parameter("strobe")));
        assert_eq!(
            r.observe(&note(36), ControlValue::Gate(true), nothing),
            Routed::Parameter { path: "strobe".into(), position: 1.0 }
        );
        assert_eq!(
            r.observe(&note(36), ControlValue::Gate(false), nothing),
            Routed::Parameter { path: "strobe".into(), position: 0.0 }
        );
    }

    #[test]
    fn toggle_flips_on_press_and_ignores_release() {
        let mut r = ControlRouter::new();
        r.map.bind(
            note(36),
            Assignment::new(Target::parameter("solo")).behaving(Behaviour::Toggle),
        );
        let on = Routed::Parameter { path: "solo".into(), position: 1.0 };
        let off = Routed::Parameter { path: "solo".into(), position: 0.0 };

        assert_eq!(r.observe(&note(36), ControlValue::Gate(true), nothing), on);
        assert_eq!(
            r.observe(&note(36), ControlValue::Gate(false), nothing),
            Routed::Ignored(Ignored::Release)
        );
        assert_eq!(r.observe(&note(36), ControlValue::Gate(true), nothing), off);
    }

    #[test]
    fn sync_toggle_corrects_a_stale_latch() {
        // Two pads on one target hold separate latches and will disagree.
        let mut r = ControlRouter::new();
        r.map.bind(
            note(36),
            Assignment::new(Target::parameter("solo")).behaving(Behaviour::Toggle),
        );
        r.sync_toggle(&note(36), true);
        assert_eq!(
            r.observe(&note(36), ControlValue::Gate(true), nothing),
            Routed::Parameter { path: "solo".into(), position: 0.0 },
            "next press must turn it off, because it is already on"
        );
    }

    #[test]
    fn an_action_fires_once_on_press() {
        let mut r = ControlRouter::new();
        r.map.bind(note(40), Assignment::new(Target::Action(Action::CueGo)));
        assert_eq!(
            r.observe(&note(40), ControlValue::Gate(true), nothing),
            Routed::Action(Action::CueGo)
        );
        assert_eq!(
            r.observe(&note(40), ControlValue::Gate(false), nothing),
            Routed::Ignored(Ignored::Release),
            "an action must not fire again on release"
        );
    }

    #[test]
    fn an_action_assignment_defaults_to_trigger() {
        // Momentary on an action would fire on press and again on release.
        let a = Assignment::new(Target::Action(Action::Blackout));
        assert_eq!(a.behaviour, Behaviour::Trigger);
        let p = Assignment::new(Target::parameter("x"));
        assert_eq!(p.behaviour, Behaviour::Momentary);
    }

    // ── pickup ──────────────────────────────────────────────────────────────

    #[test]
    fn a_fader_does_not_jump_the_parameter_on_bank_switch() {
        // The single most destructive thing a mapping can do live.
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("layer.1.opacity")));

        // Parameter is at 0.8; fader is at the bottom.
        let at = |_: &Target| Some(0.8);
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(0), at),
                   Routed::Ignored(Ignored::AwaitingPickup));
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(40), at),
                   Routed::Ignored(Ignored::AwaitingPickup));
        // Passing through 0.8 picks it up...
        assert!(matches!(
            r.observe(&cc(7), ControlValue::Midi7(110), at),
            Routed::Parameter { .. }
        ));
        // ...and from then on it is live, including going back down.
        assert!(matches!(
            r.observe(&cc(7), ControlValue::Midi7(10), at),
            Routed::Parameter { .. }
        ));
    }

    #[test]
    fn pickup_can_be_turned_off_for_a_control_that_renders_the_real_value() {
        // A phone fader drawing the true position is never out of sync.
        let mut r = ControlRouter::new();
        r.map.bind(
            ControlSource::Osc { address: "/fader".into() },
            Assignment::new(Target::parameter("a")).without_pickup(),
        );
        let out = r.observe(
            &ControlSource::Osc { address: "/fader".into() },
            ControlValue::Unit(0.1),
            |_| Some(0.9),
        );
        assert!(matches!(out, Routed::Parameter { .. }));
    }

    #[test]
    fn reset_pickup_re_arms_every_control() {
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("a")));
        let at = |_: &Target| Some(0.0);
        r.observe(&cc(7), ControlValue::Midi7(0), at);
        assert!(matches!(r.observe(&cc(7), ControlValue::Midi7(10), at), Routed::Parameter { .. }));

        r.reset_pickup();
        let elsewhere = |_: &Target| Some(1.0);
        assert_eq!(r.observe(&cc(7), ControlValue::Midi7(10), elsewhere),
                   Routed::Ignored(Ignored::AwaitingPickup));
    }

    #[test]
    fn pickup_does_not_block_a_target_with_no_known_value() {
        // An unknown value cannot jump, so holding the control would be
        // obstruction for its own sake.
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("a")));
        assert!(matches!(
            r.observe(&cc(7), ControlValue::Midi7(64), nothing),
            Routed::Parameter { .. }
        ));
    }

    // ── shaping ─────────────────────────────────────────────────────────────

    #[test]
    fn reversed_endpoints_invert_the_control() {
        let a = Assignment::new(Target::parameter("a")).ranged(1.0, 0.0);
        assert!(a.is_inverted());
        assert!((a.position(0.0) - 1.0).abs() < 1e-12);
        assert!((a.position(1.0) - 0.0).abs() < 1e-12);
        assert!((a.position(0.5) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn a_sub_range_limits_travel() {
        // A fader that must never black a layer completely.
        let a = Assignment::new(Target::parameter("a")).ranged(0.2, 0.8);
        assert!((a.position(0.0) - 0.2).abs() < 1e-12);
        assert!((a.position(1.0) - 0.8).abs() < 1e-12);
    }

    #[test]
    fn every_curve_keeps_its_endpoints_exact() {
        // A fader at the top always means fully on, whatever the shape.
        for c in [Curve::Linear, Curve::Exponential, Curve::Logarithmic, Curve::SCurve] {
            assert!((c.apply(0.0) - 0.0).abs() < 1e-12, "{c:?} at 0");
            assert!((c.apply(1.0) - 1.0).abs() < 1e-12, "{c:?} at 1");
        }
    }

    #[test]
    fn every_curve_is_monotonic() {
        for c in [Curve::Linear, Curve::Exponential, Curve::Logarithmic, Curve::SCurve] {
            let mut previous = -1.0;
            for i in 0..=100 {
                let v = c.apply(f64::from(i) / 100.0);
                assert!(v >= previous - 1e-12, "{c:?} went backwards at {i}");
                previous = v;
            }
        }
    }

    #[test]
    fn exponential_gives_finer_control_at_the_bottom() {
        assert!(Curve::Exponential.apply(0.5) < 0.5);
        assert!(Curve::Logarithmic.apply(0.5) > 0.5);
    }

    #[test]
    fn a_nan_cannot_reach_a_parameter() {
        // One NaN in a uniform poisons the frame.
        let a = Assignment::new(Target::parameter("a"));
        assert!(a.position(f64::NAN).is_finite());
        assert!(ControlValue::Unit(f64::NAN).unit().is_finite());
        let wild = Assignment::new(Target::parameter("a")).ranged(f64::NAN, f64::INFINITY);
        assert!(wild.position(0.5).is_finite());
    }

    // ── value normalisation ─────────────────────────────────────────────────

    #[test]
    fn resolutions_normalise_onto_one_scale() {
        assert!((ControlValue::Midi7(127).unit() - 1.0).abs() < 1e-12);
        assert!((ControlValue::Midi7(0).unit()).abs() < 1e-12);
        assert!((ControlValue::Midi14(16383).unit() - 1.0).abs() < 1e-12);
        // The wheel's centre detent.
        assert!((ControlValue::Midi14(8192).unit() - 0.5).abs() < 1e-4);
        assert!((ControlValue::Unit(5.0).unit() - 1.0).abs() < 1e-12);
    }

    // ── the map ─────────────────────────────────────────────────────────────

    #[test]
    fn the_map_round_trips_through_json() {
        // A map is a file an operator carries between shows.
        let mut m = ControlMap::new();
        m.bind(cc(7), Assignment::new(Target::parameter("layer.1.opacity")).ranged(1.0, 0.0));
        m.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));
        m.bind(
            ControlSource::Osc { address: "/go".into() },
            Assignment::new(Target::Action(Action::CueGo)),
        );
        m.bind(
            ControlSource::Key { code: "Space".into() },
            Assignment::new(Target::Action(Action::TapTempo)),
        );

        let json = serde_json::to_string(&m).unwrap();
        let back: ControlMap = serde_json::from_str(&json).unwrap();
        assert_eq!(m, back);
    }

    #[test]
    fn an_old_map_without_the_newer_fields_still_loads() {
        // Defaults exist so a map saved by an earlier build is not a dead file.
        let json = r#"{"entries":[{"source":{"kind":"midiCc","channel":0,"cc":7},
                        "assignment":{"target":{"kind":"parameter","path":"a"}}}]}"#;
        let m: ControlMap = serde_json::from_str(json).unwrap();
        let a = m.get(&cc(7)).unwrap();
        assert_eq!(a.from, 0.0);
        assert_eq!(a.to, 1.0);
        assert!(a.pickup);
        assert_eq!(a.behaviour, Behaviour::Momentary);
    }

    #[test]
    fn binding_order_does_not_change_the_map() {
        // Order-dependence in a container is a bug that only shows up once a
        // user's file loads in a different order than it was built.
        let mut a = ControlMap::new();
        a.bind(cc(20), Assignment::new(Target::parameter("x")));
        a.bind(cc(7), Assignment::new(Target::parameter("y")));

        let mut b = ControlMap::new();
        b.bind(cc(7), Assignment::new(Target::parameter("y")));
        b.bind(cc(20), Assignment::new(Target::parameter("x")));
        assert_eq!(a, b);
    }

    #[test]
    fn unbinding_removes_exactly_one() {
        let mut m = ControlMap::new();
        m.bind(cc(7), Assignment::new(Target::parameter("a")));
        m.bind(cc(8), Assignment::new(Target::parameter("b")));
        assert!(m.unbind(&cc(7)).is_some());
        assert!(m.unbind(&cc(7)).is_none());
        assert_eq!(m.len(), 1);
        assert!(m.get(&cc(8)).is_some());
    }

    #[test]
    fn duplicated_targets_are_findable_before_the_show() {
        let mut m = ControlMap::new();
        let t = Target::parameter("master.opacity");
        m.bind(cc(7), Assignment::new(t.clone()));
        m.bind(ControlSource::Osc { address: "/master".into() }, Assignment::new(t.clone()));
        m.bind(cc(9), Assignment::new(Target::parameter("other")));

        let dup = m.duplicated_targets();
        assert_eq!(dup.len(), 1);
        assert_eq!(dup[0].0, &t);
        assert_eq!(dup[0].1.len(), 2);
        assert_eq!(m.sources_for(&t).len(), 2);
    }

    #[test]
    fn a_map_from_another_document_lists_what_it_cannot_find() {
        let mut registry = ParameterRegistry::new();
        registry.register("layer.1.opacity", ParamSpec::unit());

        let mut m = ControlMap::new();
        m.bind(cc(7), Assignment::new(Target::parameter("layer.1.opacity")));
        m.bind(cc(8), Assignment::new(Target::parameter("layer.9.opacity")));
        m.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));

        assert_eq!(m.unresolved(&registry), vec!["layer.9.opacity"]);
    }

    // ── resolution against the registry ─────────────────────────────────────

    #[test]
    fn a_routed_position_becomes_a_parameter_value() {
        let mut registry = ParameterRegistry::new();
        let id = registry.register(
            "projector.brightness",
            ParamSpec::new(Bounds::new(0.0, 100.0).unwrap()),
        );
        let (resolved, value) =
            ControlRouter::resolve(&registry, "projector.brightness", 0.5).unwrap();
        assert_eq!(resolved, id);
        assert!((value - 50.0).abs() < 1e-9);
    }

    #[test]
    fn an_unknown_path_resolves_to_nothing_rather_than_guessing() {
        let registry = ParameterRegistry::new();
        assert!(ControlRouter::resolve(&registry, "not.registered", 0.5).is_none());
    }

    #[test]
    fn a_parameter_with_a_narrowed_sweep_is_respected() {
        // The operator set a ceiling for a reason — a projector that must not
        // exceed a brightness, a layer that must never fully black.
        let mut registry = ParameterRegistry::new();
        registry.register(
            "layer.1.opacity",
            ParamSpec::unit().with_start_stop(crate::modulation::Sweep::new(0.2, 0.8).unwrap()).unwrap(),
        );
        let (_, top) = ControlRouter::resolve(&registry, "layer.1.opacity", 1.0).unwrap();
        let (_, bottom) = ControlRouter::resolve(&registry, "layer.1.opacity", 0.0).unwrap();
        assert!((top - 0.8).abs() < 1e-9);
        assert!((bottom - 0.2).abs() < 1e-9);
    }

    // ── feedback ────────────────────────────────────────────────────────────

    #[test]
    fn feedback_reports_a_value_per_bound_control() {
        let mut r = ControlRouter::new();
        r.map.bind(cc(7), Assignment::new(Target::parameter("a")));
        r.map.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));

        let out = r.feedback(|t| match t {
            Target::Parameter { path } if path == "a" => Some(0.6),
            _ => None,
        });
        assert_eq!(out.len(), 2);
        let by_source: BTreeMap<_, _> = out.into_iter().collect();
        assert!((by_source[&cc(7)] - 0.6).abs() < 1e-12);
        assert!(
            (by_source[&note(36)]).abs() < 1e-12,
            "an action has no state; lighting its pad permanently would be a lie"
        );
    }

    // ── routing hygiene ─────────────────────────────────────────────────────

    #[test]
    fn routed_outcomes_round_trip_on_the_wire() {
        // The shell and a remote both read these as JSON; a shape that cannot
        // survive the trip is a control that silently does nothing.
        let cases = vec![
            Routed::Learning,
            Routed::Learned {
                target: Target::parameter("a"),
                displaced: Some(Assignment::new(Target::Action(Action::Blackout))),
            },
            Routed::Parameter { path: "a".into(), position: 0.25 },
            Routed::Action(Action::TriggerColumn { column: 3 }),
            Routed::Ignored(Ignored::AwaitingPickup),
        ];
        for c in cases {
            let json = serde_json::to_string(&c).unwrap();
            assert_eq!(serde_json::from_str::<Routed>(&json).unwrap(), c, "{json}");
        }
        for v in [
            ControlValue::Midi7(64),
            ControlValue::Midi14(8192),
            ControlValue::Unit(0.5),
            ControlValue::Gate(true),
        ] {
            let json = serde_json::to_string(&v).unwrap();
            assert_eq!(serde_json::from_str::<ControlValue>(&json).unwrap(), v, "{json}");
        }
    }

    #[test]
    fn an_unbound_control_says_so_rather_than_vanishing() {
        // Silent routing is indistinguishable from a broken cable.
        let mut r = ControlRouter::new();
        assert_eq!(
            r.observe(&cc(7), ControlValue::Midi7(64), nothing),
            Routed::Ignored(Ignored::Unbound)
        );
    }

    #[test]
    fn learn_captures_controls_rather_than_routing_them() {
        // Assigning a pad must not blackout the show on the way past.
        let mut r = ControlRouter::new();
        r.map.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));
        r.arm(Target::parameter("a"));
        let out = r.observe(&note(40), ControlValue::Gate(true), nothing);
        assert!(matches!(out, Routed::Learned { .. }));

        // And the armed control itself does not fire its old action either.
        let mut r = ControlRouter::new();
        r.map.bind(note(36), Assignment::new(Target::Action(Action::Blackout)));
        r.arm(Target::parameter("a"));
        let out = r.observe(&note(36), ControlValue::Gate(true), nothing);
        assert!(matches!(out, Routed::Learned { .. }), "got {out:?}");
    }

    #[test]
    fn channels_are_labelled_the_way_the_hardware_prints_them() {
        assert_eq!(cc(7).label(), "CC 7 ch 1");
        assert_eq!(
            ControlSource::MidiNote { channel: 15, note: 36 }.label(),
            "Note 36 ch 16"
        );
        assert_eq!(ControlSource::Osc { address: "/go".into() }.label(), "/go");
    }

    #[test]
    fn only_continuous_controls_are_treated_as_continuous() {
        assert!(cc(7).is_continuous());
        assert!(ControlSource::MidiPitchBend { channel: 0 }.is_continuous());
        assert!(!note(36).is_continuous());
        assert!(!ControlSource::Key { code: "KeyQ".into() }.is_continuous());
        assert!(
            !ControlSource::Osc { address: "/x".into() }.is_continuous(),
            "OSC carries its own value and is never jittery hardware"
        );
    }
}
