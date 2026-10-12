//! Remote control protocol.
//!
//! One message set, many transports. The engine is authoritative; clients hold
//! optimistic state and reconcile.
//!
//! ## State-sync-first, not request/response
//!
//! MIDI control surfaces need **pushed** state — the pads on an APC40 light up
//! to show which clips are playing, so the engine must stream state outward
//! continuously rather than answering questions. Retrofitting push onto a
//! request/response protocol is painful, so this is designed that way from the
//! start.
//!
//! ## Sized for Bluetooth LE
//!
//! Transports differ enormously: LAN WebSocket is 1–5 ms with full bandwidth;
//! **BLE gives single-digit KB/s** and cannot carry preview video at all; an
//! internet relay is 50–300 ms. The wire format is sized for the BLE budget
//! because **what fits BLE fits everything else — the reverse is not true.**
//!
//! Clients therefore declare their [`Capabilities`], and the engine adapts:
//! a BLE remote must degrade to no-preview *gracefully*, never fail.
//!
//! ## Latency honesty
//!
//! Clip launch over BLE at 50 ms is fine. A *fader* over an internet relay at
//! 200 ms is unusable and should not be offered — [`Transport::supports`] exists
//! so a UI can disable controls its transport cannot carry, rather than
//! presenting something that feels broken.

use serde::{Deserialize, Serialize};

/// Protocol version. Bumped on any breaking message change.
pub const PROTOCOL_VERSION: u16 = 1;

/// How a client is connected.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Transport {
    /// WebSocket over LAN. Full bandwidth, 1–5 ms.
    Lan,
    /// Bluetooth LE. Control only — single-digit KB/s.
    Ble,
    /// Relay over the internet. 50–300 ms.
    Relay,
    /// MIDI control surface, USB or BLE-MIDI.
    Midi,
    /// OSC over UDP.
    Osc,
}

impl Transport {
    /// Rough one-way latency budget, milliseconds.
    #[must_use]
    pub const fn typical_latency_ms(self) -> u32 {
        match self {
            Self::Lan | Self::Osc => 5,
            Self::Midi => 5,
            Self::Ble => 60,
            Self::Relay => 200,
        }
    }

    /// Whether this transport can carry a preview video stream.
    #[must_use]
    pub const fn can_carry_preview(self) -> bool {
        matches!(self, Self::Lan | Self::Relay)
    }

    /// Whether a control class is usable over this transport.
    ///
    /// Refusing a control is better than offering one that feels broken.
    #[must_use]
    pub const fn supports(self, control: ControlClass) -> bool {
        match control {
            // Discrete triggers tolerate latency; quantisation hides it anyway.
            ControlClass::Trigger => true,
            // Continuous controls need responsiveness to feel attached.
            ControlClass::Continuous => self.typical_latency_ms() <= 60,
            // Anything that can black a show must be near-instant and reliable.
            ControlClass::Critical => self.typical_latency_ms() <= 60,
        }
    }
}

/// What kind of interaction a control represents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ControlClass {
    /// Discrete, quantised actions — clip launch, cue go.
    Trigger,
    /// Faders, knobs, warp-point drags.
    Continuous,
    /// Blackout, output enable, emergency stop.
    Critical,
}

/// What a client can do, declared on connect.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    /// Protocol version the client speaks.
    pub version: u16,
    /// How it is connected.
    pub transport: Transport,
    /// Whether it wants a preview stream. Ignored if the transport can't carry one.
    pub wants_preview: bool,
    /// Whether it renders state back to hardware (lit pads) and so needs push.
    pub needs_state_push: bool,
    /// Largest message the client will accept, bytes.
    pub max_message_bytes: u32,
}

impl Capabilities {
    /// Whether preview should actually be sent.
    ///
    /// Both the client's wish **and** the transport's ability must agree.
    #[must_use]
    pub const fn preview_enabled(&self) -> bool {
        self.wants_preview && self.transport.can_carry_preview()
    }
}

/// Commands a client sends to the engine.
///
/// Deliberately small and flat: these must fit a BLE MTU without fragmentation
/// wherever possible.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "op")]
pub enum Command {
    /// Launch a clip. Quantisation is applied engine-side, not by the client,
    /// so every surface lands on the same beat.
    TriggerClip {
        /// Layer index.
        layer: u16,
        /// Column index.
        column: u16,
    },
    /// Clear a layer.
    ClearLayer {
        /// Layer index.
        layer: u16,
    },
    /// Set a parameter by its resolved dense id.
    ///
    /// Dense ids, not paths — the frame loop must never parse a string, and the
    /// wire format must never carry one it doesn't need to.
    SetParam {
        /// Resolved parameter id.
        id: u32,
        /// Normalised 0..1 value.
        value: f32,
    },
    /// Explicit operator blackout. Never implied by anything else.
    Blackout {
        /// Desired state.
        on: bool,
    },
    /// Tap tempo.
    Tap,
    /// Keepalive; also carries the client clock for latency estimation.
    Ping {
        /// Client timestamp, milliseconds.
        t_ms: u64,
    },
}

impl Command {
    /// The control class this command belongs to.
    #[must_use]
    pub const fn class(&self) -> ControlClass {
        match self {
            Self::TriggerClip { .. } | Self::ClearLayer { .. } | Self::Tap => ControlClass::Trigger,
            Self::SetParam { .. } => ControlClass::Continuous,
            Self::Blackout { .. } => ControlClass::Critical,
            Self::Ping { .. } => ControlClass::Trigger,
        }
    }
}

/// State pushed from the engine to clients.
///
/// `revision` increments on every change so a client can detect a gap and
/// request a full snapshot rather than silently drifting.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "ev")]
pub enum StateUpdate {
    /// Complete state. Sent on connect and after any detected gap.
    Snapshot {
        /// Monotonic revision.
        revision: u64,
        /// Per-layer summary.
        layers: Vec<LayerSummary>,
        /// Current tempo.
        bpm: f32,
        /// Whether output is blacked out.
        blackout: bool,
    },
    /// One layer changed.
    LayerChanged {
        /// Monotonic revision.
        revision: u64,
        /// The new layer state.
        layer: LayerSummary,
    },
    /// A parameter changed — the push that lets a surface light its pads.
    ParamChanged {
        /// Monotonic revision.
        revision: u64,
        /// Resolved parameter id.
        id: u32,
        /// Normalised value.
        value: f32,
    },
    /// Tempo or phase moved.
    ClockChanged {
        /// Monotonic revision.
        revision: u64,
        /// Current tempo.
        bpm: f32,
        /// Beat phase, 0..1.
        phase: f32,
    },
}

impl StateUpdate {
    /// The revision this update carries.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        match self {
            Self::Snapshot { revision, .. }
            | Self::LayerChanged { revision, .. }
            | Self::ParamChanged { revision, .. }
            | Self::ClockChanged { revision, .. } => *revision,
        }
    }
}

/// Minimal per-layer state for a remote surface.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayerSummary {
    /// Layer index.
    pub index: u16,
    /// Playing clip's column, if any.
    pub active_column: Option<u16>,
    /// 0..1.
    pub opacity: f32,
    /// Excluded from the composite.
    pub bypassed: bool,
}

/// Tracks revisions so a client can detect a gap.
#[derive(Debug, Clone, Default)]
pub struct RevisionTracker {
    last_seen: u64,
}

impl RevisionTracker {
    /// A fresh tracker.
    #[must_use]
    pub const fn new() -> Self {
        Self { last_seen: 0 }
    }

    /// Accepts an update, reporting whether a gap was detected.
    ///
    /// A gap means messages were lost, so the client must request a full
    /// snapshot — **silently continuing would leave the surface showing state
    /// the engine does not have**, which on a lit controller is worse than
    /// showing nothing.
    pub fn accept(&mut self, update: &StateUpdate) -> Reconcile {
        let rev = update.revision();
        // A snapshot resynchronises unconditionally.
        if matches!(update, StateUpdate::Snapshot { .. }) {
            self.last_seen = rev;
            return Reconcile::Applied;
        }
        if rev == self.last_seen + 1 {
            self.last_seen = rev;
            Reconcile::Applied
        } else if rev <= self.last_seen {
            // Duplicate or reordered — safe to drop, state is already newer.
            Reconcile::Stale
        } else {
            Reconcile::GapDetected {
                missing_from: self.last_seen + 1,
            }
        }
    }
}

/// Outcome of accepting a state update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reconcile {
    /// Applied in order.
    Applied,
    /// Older than what is already held; drop it.
    Stale,
    /// Messages were lost — request a snapshot.
    GapDetected {
        /// First revision that was missed.
        missing_from: u64,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ble_cannot_carry_preview_but_can_trigger() {
        assert!(!Transport::Ble.can_carry_preview());
        assert!(Transport::Ble.supports(ControlClass::Trigger));
    }

    #[test]
    fn relay_refuses_continuous_and_critical_controls() {
        // 200ms on a fader feels broken; better to disable it than offer it.
        assert!(!Transport::Relay.supports(ControlClass::Continuous));
        assert!(!Transport::Relay.supports(ControlClass::Critical));
        assert!(Transport::Relay.supports(ControlClass::Trigger));
    }

    #[test]
    fn preview_requires_both_want_and_ability() {
        let ble = Capabilities {
            version: PROTOCOL_VERSION,
            transport: Transport::Ble,
            wants_preview: true,
            needs_state_push: true,
            max_message_bytes: 180,
        };
        assert!(!ble.preview_enabled(), "BLE must degrade, not promise preview");

        let lan = Capabilities { transport: Transport::Lan, ..ble.clone() };
        assert!(lan.preview_enabled());
    }

    #[test]
    fn commands_fit_a_ble_mtu() {
        // The whole wire format is sized for the tightest transport. A typical
        // BLE ATT MTU is ~185 bytes; every command must fit without fragmenting.
        let cmds = vec![
            Command::TriggerClip { layer: 3, column: 7 },
            Command::SetParam { id: 4_294_967_000, value: 0.123_456 },
            Command::Blackout { on: true },
            Command::Tap,
            Command::Ping { t_ms: u64::MAX },
        ];
        for c in cmds {
            let n = serde_json::to_vec(&c).unwrap().len();
            assert!(n <= 180, "{c:?} serialises to {n} bytes, too big for BLE");
        }
    }

    #[test]
    fn blackout_is_classified_critical() {
        // Anything that can black a live show must be treated as such.
        assert_eq!(Command::Blackout { on: true }.class(), ControlClass::Critical);
    }

    #[test]
    fn in_order_updates_apply() {
        let mut t = RevisionTracker::new();
        for r in 1..=5 {
            let u = StateUpdate::ParamChanged { revision: r, id: 1, value: 0.5 };
            assert_eq!(t.accept(&u), Reconcile::Applied);
        }
    }

    #[test]
    fn a_missed_update_is_detected_not_silently_applied() {
        let mut t = RevisionTracker::new();
        t.accept(&StateUpdate::ParamChanged { revision: 1, id: 1, value: 0.0 });
        let gap = t.accept(&StateUpdate::ParamChanged { revision: 5, id: 1, value: 1.0 });
        assert_eq!(gap, Reconcile::GapDetected { missing_from: 2 });
    }

    #[test]
    fn snapshot_resynchronises_after_a_gap() {
        let mut t = RevisionTracker::new();
        t.accept(&StateUpdate::ParamChanged { revision: 1, id: 1, value: 0.0 });
        t.accept(&StateUpdate::ParamChanged { revision: 9, id: 1, value: 0.0 });
        let snap = StateUpdate::Snapshot {
            revision: 9,
            layers: vec![],
            bpm: 128.0,
            blackout: false,
        };
        assert_eq!(t.accept(&snap), Reconcile::Applied);
        // And the stream continues cleanly from there.
        let next = StateUpdate::ParamChanged { revision: 10, id: 1, value: 0.2 };
        assert_eq!(t.accept(&next), Reconcile::Applied);
    }

    #[test]
    fn reordered_duplicates_are_dropped_not_applied() {
        let mut t = RevisionTracker::new();
        t.accept(&StateUpdate::ParamChanged { revision: 1, id: 1, value: 0.0 });
        t.accept(&StateUpdate::ParamChanged { revision: 2, id: 1, value: 0.0 });
        let old = StateUpdate::ParamChanged { revision: 2, id: 1, value: 9.9 };
        assert_eq!(t.accept(&old), Reconcile::Stale, "must not regress state");
    }

    #[test]
    fn protocol_round_trips_through_json() {
        let u = StateUpdate::Snapshot {
            revision: 42,
            layers: vec![LayerSummary {
                index: 0,
                active_column: Some(3),
                opacity: 0.75,
                bypassed: false,
            }],
            bpm: 174.0,
            blackout: false,
        };
        let s = serde_json::to_string(&u).unwrap();
        assert_eq!(serde_json::from_str::<StateUpdate>(&s).unwrap(), u);
    }
}
