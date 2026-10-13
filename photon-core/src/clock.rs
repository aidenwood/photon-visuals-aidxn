//! Tempo and phase authority — the single definition of musical time.
//!
//! Beat-synced clip playback ([`Transport::BpmSync`](crate::doc::Transport)) and
//! beat-synced modulation ([`ModSource::BeatLfo`](crate::doc::ModSource)) both
//! read their position from here, so there is exactly one musical now.
//!
//! ## Tempo and phase are separable sources
//!
//! rekordbox publishes usable BPM over Ableton Link but **not** a trustworthy
//! downbeat, so in a real CDJ rig tempo arrives from one transport and the
//! downbeat from another (Pro DJ Link, MIDI SPP, or the operator's thumb). The
//! clock models that directly: every tempo input names its [`TempoSource`] and
//! every phase input names its [`PhaseSource`], and the clock accepts input only
//! from the configured authority for that axis. A Link beat cannot move the
//! downbeat when phase is owned by Pro DJ Link, and no amount of mis-wiring in
//! the shell can make it.
//!
//! ## Predict, do not react
//!
//! Onset detection is tens of milliseconds late and MIDI clock jitters, so a
//! clock that *follows* its input is always behind and always visibly unsteady.
//! Instead the clock holds a tempo+phase **estimate** and runs free; it predicts
//! boundaries ahead of time ([`Clock::beats_after`], [`Clock::seconds_until`]) so
//! a clip launch can be scheduled rather than chased.
//!
//! A detected beat is then a **correction, not a command**:
//!
//! - It is timestamped at *capture* time and the clock back-projects its own
//!   estimate to that instant, so detection latency is cancelled instead of
//!   being absorbed as phase error.
//! - The resulting error is **slewed in** over time ([`Slew`]), never jumped. A
//!   hard jump mid-show is a visible stutter across every synced layer at once.
//! - The slew is rate-limited as a fraction of nominal tempo, so absorbing an
//!   error is at worst a slight, musical push — not a warp.
//! - Errors below a deadband are detector jitter and are ignored; errors above a
//!   ceiling are mis-detects and are rejected. Chasing either is worse than
//!   ignoring both.
//!
//! ## No wall clock
//!
//! Nothing here reads time. The shell owns the clock source and passes
//! timestamps in, which is what keeps this portable and what makes a three-hour
//! show reproducible in a unit test.

use crate::beat::{DetectedBeat, TempoEstimate, USABLE_CONFIDENCE};
use crate::doc::{ClockConfig, Id, PhaseSource, Quantise, Rational, TempoSource};

/// Slowest tempo accepted, BPM. Below this, tap intervals collide with the
/// tap-series timeout and a "tempo" is indistinguishable from two unrelated taps.
pub const MIN_BPM: f64 = 20.0;
/// Fastest tempo accepted, BPM.
pub const MAX_BPM: f64 = 400.0;
/// Tempo used when an input is unusable but a clock must still exist.
pub const DEFAULT_BPM: f64 = 120.0;

/// Tolerance, in fractions of a quantise period, for "already on the boundary".
///
/// Musical position is `f64`, so a position that *should* be exactly on a bar
/// line lands a few ULPs either side of it. Without this, half the time a launch
/// quantised to the bar it is already on would wait a whole extra bar.
const BOUNDARY_EPS: f64 = 1e-9;

/// Convergence tolerance in beats for the [`Clock::seconds_until`] solve.
const SOLVE_EPS: f64 = 1e-12;

/// Residual correction, in beats, treated as settled.
///
/// An exponential never reaches zero, so without a floor the clock would carry a
/// correction forever and never report itself locked. A nanobeat is half a
/// nanosecond at 120 BPM — far below anything a frame can express.
const SETTLED_BEATS: f64 = 1e-9;

// ─── correction policy ───────────────────────────────────────────────────────

/// How a detected phase error is absorbed.
///
/// Correction is an exponential approach with a hard ceiling on how far the
/// clock may deviate from nominal tempo while absorbing it. The exponential
/// guarantees it never overshoots; the ceiling guarantees it never warps.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Slew {
    /// Fraction of the remaining error removed per second, as a rate constant.
    /// `2.5` settles a correction in roughly 1.5 s — fast enough to be locked by
    /// the next bar, slow enough that nobody sees it happen.
    pub rate_per_second: f64,
    /// Errors smaller than this (in beats) are ignored as detector jitter.
    /// Correcting for noise is how a clock acquires a wobble it never loses.
    pub deadband_beats: f64,
    /// Errors larger than this (in beats) are rejected as mis-detections. A
    /// genuine re-cue is the operator's job, not the detector's.
    pub max_error_beats: f64,
    /// Ceiling on tempo deviation while slewing, as a fraction of nominal.
    /// `0.05` means the clock may run at most 5% fast or slow to absorb an error.
    pub max_rate_ratio: f64,
}

impl Default for Slew {
    fn default() -> Self {
        Self {
            rate_per_second: 2.5,
            deadband_beats: 0.01,
            max_error_beats: 0.25,
            max_rate_ratio: 0.05,
        }
    }
}

impl Slew {
    /// Clamps the policy into a range that cannot misbehave.
    ///
    /// `max_rate_ratio` is held below 1.0 because at 1.0 the clock could stall
    /// musical time entirely while correcting backwards, and position must be
    /// monotonic for prediction and for quantise solving to terminate.
    #[must_use]
    pub fn sanitised(self) -> Self {
        Self {
            rate_per_second: finite_or(self.rate_per_second, 2.5).clamp(0.01, 100.0),
            deadband_beats: finite_or(self.deadband_beats, 0.0).clamp(0.0, 0.25),
            max_error_beats: finite_or(self.max_error_beats, 0.25).clamp(0.0, 0.5),
            max_rate_ratio: finite_or(self.max_rate_ratio, 0.05).clamp(0.001, 0.5),
        }
    }

    /// Correction applied after `dt` seconds for a given pending error.
    ///
    /// Closed form of the rate-limited integrator `Ȧ = min(rate·(P−A), cap)`,
    /// solved exactly rather than approximated: the ceiling binds while the
    /// exponential *would* be steeper than it, and hands over at the point where
    /// the two **slopes** match — `P − cap/rate` of error absorbed — not where
    /// the two curves cross, which is later and would over-correct by a
    /// measurable few milliseconds of phase.
    ///
    /// Solving it exactly is what makes this composable: stepping it frame by
    /// frame and evaluating it once over the whole interval give the same
    /// answer, so [`Clock::beats_after`] can predict through a correction that
    /// has not finished yet and [`Clock::seconds_until`] can invert it.
    fn applied(self, pending: f64, dt: f64, beats_per_second: f64) -> f64 {
        if pending == 0.0 || dt <= 0.0 {
            return 0.0;
        }
        let remaining = pending.abs();
        let rate = self.rate_per_second;
        let cap = beats_per_second * self.max_rate_ratio;
        let magnitude = if cap <= 0.0 {
            0.0
        } else if remaining * rate <= cap {
            remaining * (1.0 - (-rate * dt).exp())
        } else {
            let while_capped = remaining - cap / rate;
            let handover = while_capped / cap;
            if dt <= handover {
                cap * dt
            } else {
                while_capped + (cap / rate) * (1.0 - (-rate * (dt - handover)).exp())
            }
        };
        magnitude.copysign(pending)
    }
}

/// What the clock did with a phase observation.
///
/// Returned rather than logged so the shell can surface a detector that is being
/// rejected — a silently ignored input looks identical to a dead cable.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Correction {
    /// Accepted; the error is being slewed in. Carries the measured error in
    /// beats (positive = the clock is running ahead of the music).
    Slewing(f64),
    /// Accepted but smaller than [`Slew::deadband_beats`]; ignored as jitter.
    WithinDeadband(f64),
    /// Larger than [`Slew::max_error_beats`]; ignored as a probable mis-detect.
    Rejected(f64),
    /// Applied as a hard jump. Only ever reachable while the clock is stopped,
    /// where a jump cannot be seen.
    Snapped(f64),
    /// The input named a source that is not the configured phase authority.
    NotAuthoritative,
}

impl Correction {
    /// The measured error in beats, where there was one.
    #[must_use]
    pub const fn error(self) -> Option<f64> {
        match self {
            Self::Slewing(e) | Self::WithinDeadband(e) | Self::Rejected(e) | Self::Snapped(e) => {
                Some(e)
            }
            Self::NotAuthoritative => None,
        }
    }

    /// Whether the observation moved or will move the clock.
    #[must_use]
    pub const fn changed_phase(self) -> bool {
        matches!(self, Self::Slewing(_) | Self::Snapped(_))
    }
}

// ─── tap tempo ───────────────────────────────────────────────────────────────

/// Taps retained. Seven intervals is enough for a stable median and short enough
/// that the estimate still tracks an operator correcting themselves.
const TAP_CAPACITY: usize = 8;

/// Gap after which a tap starts a new series rather than extending the old one.
/// Also the slowest representable tempo's beat (60/[`MIN_BPM`]), so a legitimate
/// slow tap is never mistaken for the start of a new count-in.
pub const TAP_TIMEOUT_SECS: f64 = 60.0 / MIN_BPM;

/// Interval deviation from the median beyond which a tap interval is discarded.
pub const TAP_OUTLIER_TOLERANCE: f64 = 0.35;

/// Rolling tap-tempo estimator.
///
/// Fixed-size and allocation-free so it can live in the audio-adjacent path.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TapTempo {
    taps: [f64; TAP_CAPACITY],
    len: usize,
}

impl Default for TapTempo {
    fn default() -> Self {
        Self::new()
    }
}

impl TapTempo {
    /// An empty estimator.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            taps: [0.0; TAP_CAPACITY],
            len: 0,
        }
    }

    /// Records a tap at `at` seconds.
    ///
    /// Returns `true` if this tap began a new series — either the first tap, a
    /// tap after [`TAP_TIMEOUT_SECS`] of silence, or a non-monotonic timestamp.
    /// The caller needs to know, because the first tap of a count-in is the one
    /// the operator means as the downbeat.
    pub fn tap(&mut self, at: f64) -> bool {
        if !at.is_finite() {
            return false;
        }
        let new_series = match self.last() {
            Some(prev) => at <= prev || at - prev > TAP_TIMEOUT_SECS,
            None => true,
        };
        if new_series {
            self.len = 0;
        }
        if self.len == TAP_CAPACITY {
            self.taps.rotate_left(1);
            self.len -= 1;
        }
        self.taps[self.len] = at;
        self.len += 1;
        new_series
    }

    /// Forgets the current series.
    pub fn clear(&mut self) {
        self.len = 0;
    }

    /// Taps in the current series.
    #[must_use]
    pub const fn len(&self) -> usize {
        self.len
    }

    /// Whether no taps are held.
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Timestamp of the most recent tap.
    #[must_use]
    pub fn last(&self) -> Option<f64> {
        (self.len > 0).then(|| self.taps[self.len - 1])
    }

    /// Current BPM estimate, or `None` until two taps exist or if the result is
    /// outside [`MIN_BPM`]..=[`MAX_BPM`].
    ///
    /// With three or more intervals the estimate is the mean of the intervals
    /// that sit within [`TAP_OUTLIER_TOLERANCE`] of their median. A missed tap
    /// doubles one interval, and a mean alone would swallow that as a 50% tempo
    /// error — the median will not, because an operator's mistake is one sample
    /// and their intent is all the others.
    #[must_use]
    pub fn bpm(&self) -> Option<f64> {
        let n = self.len.checked_sub(1)?;
        if n == 0 {
            return None;
        }
        let mut intervals = [0.0f64; TAP_CAPACITY - 1];
        for (i, interval) in intervals.iter_mut().enumerate().take(n) {
            *interval = self.taps[i + 1] - self.taps[i];
        }
        let mean = if n >= 3 {
            let median = median_of(&intervals[..n]);
            let (mut sum, mut kept) = (0.0, 0usize);
            for &iv in &intervals[..n] {
                if (iv - median).abs() <= median * TAP_OUTLIER_TOLERANCE {
                    sum += iv;
                    kept += 1;
                }
            }
            // Every interval an outlier means the median is the only thing left
            // worth believing.
            if kept == 0 {
                median
            } else {
                sum / kept as f64
            }
        } else {
            intervals[..n].iter().sum::<f64>() / n as f64
        };
        if mean <= 0.0 {
            return None;
        }
        let bpm = 60.0 / mean;
        (MIN_BPM..=MAX_BPM).contains(&bpm).then_some(bpm)
    }
}

/// What one tap did to the clock.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TapOutcome {
    /// The estimator's BPM after this tap, if it has one yet.
    pub bpm: Option<f64>,
    /// Whether the estimate was adopted as the clock's tempo. False when tempo
    /// is owned by another source — tapping still measures, it just does not
    /// steer.
    pub tempo_applied: bool,
    /// What the tap did to phase.
    pub phase: Correction,
    /// Taps in the current series, for a count-in indicator.
    pub taps: usize,
}

// ─── the clock ───────────────────────────────────────────────────────────────

/// Tempo and phase authority.
///
/// Advanced by elapsed time from the shell; never reads a clock itself.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Clock {
    bpm: f64,
    tempo_source: TempoSource,
    phase_source: PhaseSource,
    /// Continuous position on the beat grid. Integers are beats.
    beats: f64,
    /// Beat position that counts as the start of a bar, in `[0, beats_per_bar)`.
    ///
    /// Held separately from `beats` so that finding the downbeat **relabels**
    /// bars without moving the beat grid. A whole-beat bar rotation changes
    /// which beat is accented; it must not shift every beat-synced clip.
    bar_origin: f64,
    beats_per_bar: f64,
    running: bool,
    /// Last timestamp handed in, for back-projecting observations and for
    /// converting a wait into an absolute time.
    last_time: Option<f64>,
    /// Phase error still to be absorbed, in beats. Positive = clock is ahead.
    pending: f64,
    slew: Slew,
    tap_tempo: TapTempo,
}

impl Default for Clock {
    fn default() -> Self {
        Self::new(DEFAULT_BPM)
    }
}

impl Clock {
    /// A stopped clock at `bpm`, 4 beats to the bar, manual tempo and phase.
    ///
    /// An unusable `bpm` falls back to [`DEFAULT_BPM`] rather than failing: a
    /// document with a corrupt tempo must still open. Runtime tempo input is
    /// held to a stricter standard — see [`Clock::set_bpm`].
    #[must_use]
    pub fn new(bpm: f64) -> Self {
        Self {
            bpm: sane_bpm(bpm).unwrap_or(DEFAULT_BPM),
            tempo_source: TempoSource::Manual,
            phase_source: PhaseSource::FollowTempo,
            beats: 0.0,
            bar_origin: 0.0,
            beats_per_bar: 4.0,
            running: false,
            last_time: None,
            pending: 0.0,
            slew: Slew::default(),
            tap_tempo: TapTempo::new(),
        }
    }

    /// A clock configured from the document.
    #[must_use]
    pub fn from_config(config: &ClockConfig) -> Self {
        Self {
            tempo_source: config.tempo_source,
            phase_source: config.phase_source,
            ..Self::new(config.bpm)
        }
    }

    /// Sets the bar length in beats. Zero or non-finite is ignored.
    #[must_use]
    pub fn with_beats_per_bar(mut self, beats: u32) -> Self {
        if beats > 0 {
            self.beats_per_bar = f64::from(beats);
            self.bar_origin = self.bar_origin.rem_euclid(self.beats_per_bar);
        }
        self
    }

    /// Sets the correction policy.
    #[must_use]
    pub fn with_slew(mut self, slew: Slew) -> Self {
        self.slew = slew.sanitised();
        self
    }

    // ── tempo ───────────────────────────────────────────────────────────────

    /// Current tempo estimate in BPM.
    #[must_use]
    pub const fn bpm(&self) -> f64 {
        self.bpm
    }

    /// Beats per second at the nominal tempo, excluding any in-flight correction.
    #[must_use]
    pub fn beats_per_second(&self) -> f64 {
        self.bpm / 60.0
    }

    /// Seconds per beat at the nominal tempo.
    #[must_use]
    pub fn beat_period(&self) -> f64 {
        60.0 / self.bpm
    }

    /// Beats elapsed per composition frame at an exact cadence.
    ///
    /// Takes [`Rational`] because the composition rate is the one genuinely
    /// exact rate in play: 30000/1001 is not 29.97, and a per-frame musical
    /// increment built from the rounded value drifts by a visible fraction of a
    /// beat over a set. Tempo itself stays `f64` — it arrives from taps and from
    /// Link as a float and pretending otherwise would be false precision.
    #[must_use]
    pub fn beats_per_frame(&self, rate: Rational) -> f64 {
        let fps = rate.to_f64();
        if fps <= 0.0 {
            0.0
        } else {
            self.beats_per_second() / fps
        }
    }

    /// Playback rate multiplier for a [`Transport::BpmSync`](crate::doc::Transport)
    /// clip: how fast a clip of exact length `clip_len` seconds must run to span
    /// `loop_beats` beats of musical time.
    ///
    /// Returns 1.0 for degenerate input, since "do not resample" is the only
    /// harmless answer.
    #[must_use]
    pub fn bpm_sync_rate(&self, clip_len: Rational, loop_beats: u16) -> f64 {
        let secs = clip_len.to_f64();
        let musical = f64::from(loop_beats) * self.beat_period();
        if secs <= 0.0 || musical <= 0.0 {
            1.0
        } else {
            secs / musical
        }
    }

    /// The configured tempo authority.
    #[must_use]
    pub const fn tempo_source(&self) -> TempoSource {
        self.tempo_source
    }

    /// The configured phase authority. May differ from the tempo authority —
    /// that separation is the point.
    #[must_use]
    pub const fn phase_source(&self) -> PhaseSource {
        self.phase_source
    }

    /// Changes the tempo authority.
    pub fn set_tempo_source(&mut self, source: TempoSource) {
        self.tempo_source = source;
    }

    /// Changes the phase authority.
    pub fn set_phase_source(&mut self, source: PhaseSource) {
        self.phase_source = source;
    }

    /// Offers a tempo from `from`. Returns whether it was adopted.
    ///
    /// Rejected unless `from` is the configured tempo authority, and rejected if
    /// outside [`MIN_BPM`]..=[`MAX_BPM`] — a wild BPM from a transport is a bug
    /// upstream, and clamping it would hide the bug while still ruining the show.
    ///
    /// **Musical position is preserved across a tempo change.** Only the rate of
    /// future advance changes; the beat the music is on does not move.
    pub fn set_bpm(&mut self, from: TempoSource, bpm: f64) -> bool {
        if from != self.tempo_source {
            return false;
        }
        match sane_bpm(bpm) {
            Some(bpm) => {
                self.bpm = bpm;
                true
            }
            None => false,
        }
    }

    // ── run state ───────────────────────────────────────────────────────────

    /// Whether musical time is advancing.
    #[must_use]
    pub const fn is_running(&self) -> bool {
        self.running
    }

    /// Starts advancing, with `at` as the timing epoch.
    ///
    /// Re-seats the epoch so that time spent stopped is not dumped into the
    /// first frame as a multi-beat jump.
    pub fn start(&mut self, at: f64) {
        self.running = true;
        if at.is_finite() {
            self.last_time = Some(at);
        }
    }

    /// Stops advancing. Position, tempo and pending correction are retained.
    pub fn stop(&mut self) {
        self.running = false;
    }

    /// Returns to bar 1 beat 1 with no pending correction. Tempo is untouched.
    pub fn reset(&mut self) {
        self.beats = 0.0;
        self.bar_origin = 0.0;
        self.pending = 0.0;
        self.tap_tempo.clear();
    }

    /// Advances to an absolute timestamp, returning the delta actually applied.
    ///
    /// The first call only seats the epoch. A timestamp that goes backwards
    /// applies nothing: musical position must be monotonic, and a shell that
    /// hands over a non-monotonic clock should not be able to rewind the show.
    pub fn advance_to(&mut self, now: f64) -> f64 {
        if !now.is_finite() {
            return 0.0;
        }
        let dt = match self.last_time {
            Some(prev) => (now - prev).max(0.0),
            None => 0.0,
        };
        self.last_time = Some(now);
        self.advance_by(dt);
        dt
    }

    /// Advances by an elapsed interval in seconds.
    ///
    /// The primitive; [`Clock::advance_to`] is the convenience over it. Does
    /// nothing while stopped — including no slewing, because a correction
    /// applied to a stopped clock would land as a jump the moment it starts.
    pub fn advance_by(&mut self, dt: f64) {
        if !self.running || !dt.is_finite() || dt <= 0.0 {
            return;
        }
        let bps = self.beats_per_second();
        let applied = self.slew.applied(self.pending, dt, bps);
        self.beats += dt * bps + applied;
        self.pending -= applied;
        if self.pending.abs() < SETTLED_BEATS {
            self.pending = 0.0;
        }
    }

    // ── position ────────────────────────────────────────────────────────────

    /// Continuous position on the beat grid. Integers are beats.
    #[must_use]
    pub const fn beat_position(&self) -> f64 {
        self.beats
    }

    /// Continuous position in bars, relative to the current downbeat.
    #[must_use]
    pub fn bar_position(&self) -> f64 {
        (self.beats - self.bar_origin) / self.beats_per_bar
    }

    /// Position within the current beat, `0.0..1.0`.
    #[must_use]
    pub fn beat_phase(&self) -> f64 {
        self.beats.rem_euclid(1.0)
    }

    /// Position within the current bar, `0.0..1.0`.
    #[must_use]
    pub fn bar_phase(&self) -> f64 {
        self.bar_position().rem_euclid(1.0)
    }

    /// Which beat of the bar, zero-based. `0` is the downbeat.
    #[must_use]
    pub fn beat_in_bar(&self) -> u32 {
        let rel = (self.beats - self.bar_origin).rem_euclid(self.beats_per_bar);
        rel as u32
    }

    /// Bar length in beats.
    #[must_use]
    pub fn beats_per_bar(&self) -> u32 {
        self.beats_per_bar as u32
    }

    /// Position within a window of arbitrary musical length, `0.0..1.0`.
    ///
    /// Drives both the loop position of a `BpmSync` clip and the ramp of a
    /// `BeatLfo` — they are the same question asked by different subsystems, and
    /// answering it in one place is what keeps a 1-bar LFO and a 1-bar loop in
    /// agreement about where "the top" is.
    #[must_use]
    pub fn loop_phase(&self, beats: f64) -> f64 {
        if !beats.is_finite() || beats <= 0.0 {
            return 0.0;
        }
        ((self.beats - self.bar_origin) / beats).rem_euclid(1.0)
    }

    // ── prediction ──────────────────────────────────────────────────────────

    /// Predicted beat position `dt` seconds from now.
    ///
    /// Forwards, this includes any in-flight correction, so a boundary scheduled
    /// during a correction still lands where it was promised. Backwards (`dt` is
    /// negative) it is nominal only — corrections already applied are baked into
    /// the current position, and the pending one has not happened yet.
    ///
    /// Returns the current position while stopped.
    #[must_use]
    pub fn beats_after(&self, dt: f64) -> f64 {
        if !self.running || !dt.is_finite() {
            return self.beats;
        }
        let bps = self.beats_per_second();
        if dt <= 0.0 {
            return self.beats + dt * bps;
        }
        self.beats + dt * bps + self.slew.applied(self.pending, dt, bps)
    }

    /// Predicted beat position at an absolute timestamp.
    ///
    /// `None` before the first [`Clock::advance_to`], when there is no epoch to
    /// measure against, and `None` for a non-finite timestamp — "where was the
    /// clock at NaN" has no answer, and answering it with the current position
    /// would turn a lost timestamp into a silent zero-latency back-projection.
    #[must_use]
    pub fn beat_at(&self, time: f64) -> Option<f64> {
        if !time.is_finite() {
            return None;
        }
        let last = self.last_time?;
        Some(self.beats_after(time - last))
    }

    /// Phase error, in beats, still to be absorbed. Positive = running ahead.
    #[must_use]
    pub const fn pending_correction(&self) -> f64 {
        self.pending
    }

    // ── quantise ────────────────────────────────────────────────────────────

    /// Beats until the next boundary for `q`.
    ///
    /// Zero when already on the boundary — within a tolerance, because an
    /// accumulated `f64` position lands a few ULPs either side of a bar line and
    /// a launch quantised to the bar it is on must not wait a whole extra bar.
    /// Zero also for
    /// [`Quantise::Immediate`]. `Bars(0)` is treated as immediate: a wait of
    /// zero bars is not a wait.
    #[must_use]
    pub fn beats_until(&self, q: Quantise) -> f64 {
        let Some((period, origin)) = self.grid(q) else {
            return 0.0;
        };
        let rel = (self.beats - origin) / period;
        let rounded = rel.round();
        let next = if (rel - rounded).abs() < BOUNDARY_EPS {
            rounded
        } else {
            rel.ceil()
        };
        (next * period + origin - self.beats).max(0.0)
    }

    /// Seconds until the next boundary for `q`.
    ///
    /// Accounts for an in-flight correction by inverting [`Clock::beats_after`]
    /// — while slewing, the clock is not running at nominal tempo and a naive
    /// `beats / bps` would schedule the launch early. Infinite while stopped,
    /// because a stopped clock never reaches the boundary.
    #[must_use]
    pub fn seconds_until(&self, q: Quantise) -> f64 {
        let want = self.beats_until(q);
        if want <= 0.0 {
            return 0.0;
        }
        if !self.running {
            return f64::INFINITY;
        }
        let bps = self.beats_per_second();
        let mut t = want / bps;
        // The rate cap holds |d(correction)/dt| strictly below bps, so advance
        // is monotone in t and this fixed point converges in a handful of steps.
        for _ in 0..16 {
            let err = want - (self.beats_after(t) - self.beats);
            if err.abs() < SOLVE_EPS {
                break;
            }
            t += err / bps;
        }
        t.max(0.0)
    }

    /// Composition frames until the next boundary for `q`, at an exact cadence.
    ///
    /// Fractional on purpose: the shell decides whether to round up to the next
    /// frame or to sub-frame schedule. Infinite while stopped.
    #[must_use]
    pub fn frames_until(&self, q: Quantise, rate: Rational) -> f64 {
        let fps = rate.to_f64();
        if fps <= 0.0 {
            return 0.0;
        }
        self.seconds_until(q) * fps
    }

    /// Absolute timestamp of the next boundary for `q`.
    ///
    /// `None` before the first [`Clock::advance_to`] or while stopped.
    #[must_use]
    pub fn time_of_next(&self, q: Quantise) -> Option<f64> {
        let last = self.last_time?;
        let secs = self.seconds_until(q);
        secs.is_finite().then_some(last + secs)
    }

    /// Period and origin, in beats, of the grid `q` quantises to.
    fn grid(&self, q: Quantise) -> Option<(f64, f64)> {
        match q {
            Quantise::Immediate => None,
            Quantise::Beat => Some((1.0, 0.0)),
            Quantise::Bar => Some((self.beats_per_bar, self.bar_origin)),
            Quantise::Bars(0) => None,
            Quantise::Bars(n) => Some((f64::from(n) * self.beats_per_bar, self.bar_origin)),
        }
    }

    // ── corrections ─────────────────────────────────────────────────────────

    /// Reports a beat detected at `at` seconds — the time the beat *happened*,
    /// not the time the detector noticed.
    ///
    /// The clock back-projects its own estimate to `at` and corrects against
    /// that, so the detector's latency is cancelled rather than being absorbed
    /// as a permanent phase offset. Passing "now" instead of the capture
    /// timestamp is the classic way to end up permanently late.
    ///
    /// A non-finite `at` is [`Correction::Rejected`]: a detector that has lost
    /// its timestamp must not be able to move phase at all.
    pub fn observe_beat(&mut self, from: PhaseSource, at: f64) -> Correction {
        if !self.accepts_phase_from(from) {
            return Correction::NotAuthoritative;
        }
        if !at.is_finite() {
            return Correction::Rejected(0.0);
        }
        let Some(error) = self.error_against_grid(from, at, 1.0) else {
            return Correction::NotAuthoritative;
        };
        self.queue(error)
    }

    /// Reports a downbeat detected at `at` seconds.
    ///
    /// The whole-beat part of the error is applied **immediately** and the
    /// fractional part is slewed. Rotating which beat is beat 1 is a relabel —
    /// it does not move a single beat of the grid, so nothing on screen jumps —
    /// whereas sliding the grid by two beats to find the "1" would drag every
    /// synced layer with it.
    ///
    /// A rejected observation changes **nothing** — not the grid and not the
    /// rotation. Relabelling bars on a detection the clock has just declared a
    /// mis-detect is the same wrong answer as slewing to it, and worse for being
    /// invisible: [`Correction::Rejected`] reports no phase change.
    ///
    /// A non-finite `at` is likewise rejected.
    pub fn observe_downbeat(&mut self, from: PhaseSource, at: f64) -> Correction {
        if !self.accepts_phase_from(from) {
            return Correction::NotAuthoritative;
        }
        if !at.is_finite() {
            return Correction::Rejected(0.0);
        }
        let Some(projected) = self.beat_at(at) else {
            return Correction::NotAuthoritative;
        };
        let rel = projected - self.bar_origin;
        let error = rel - (rel / self.beats_per_bar).round() * self.beats_per_bar;
        // Split: whole beats rotate the bar, the remainder is a grid correction.
        let whole = error.round();
        // Judge the grid correction before applying either half, so a mis-detect
        // cannot rotate the bar on its way to being thrown away.
        if matches!(self.verdict(error - whole), Correction::Rejected(_)) {
            return Correction::Rejected(error);
        }
        if whole != 0.0 {
            self.bar_origin = (self.bar_origin + whole).rem_euclid(self.beats_per_bar);
        }
        match self.queue(error - whole) {
            // Report the error the detector actually found, not the residue.
            Correction::Slewing(_) => Correction::Slewing(error),
            Correction::WithinDeadband(_) if whole != 0.0 => Correction::Snapped(error),
            Correction::WithinDeadband(_) => Correction::WithinDeadband(error),
            // Rejection was decided above, before anything was applied.
            other => other,
        }
    }

    /// Hard-sets the downbeat so that `at` is bar 1 beat 1.
    ///
    /// Refuses while running (returning `false`) — this is the one operation
    /// that jumps, and a jump mid-show is visible on every synced layer at once.
    /// Mid-show downbeat changes go through [`Clock::observe_downbeat`].
    pub fn force_downbeat(&mut self, at: f64) -> bool {
        if self.running || !at.is_finite() {
            return false;
        }
        self.beats = self.beats.round();
        self.bar_origin = self.beats.rem_euclid(self.beats_per_bar);
        self.pending = 0.0;
        self.last_time = Some(at);
        true
    }

    /// Feeds an operator tap.
    ///
    /// One tap stream, two independently gated effects: it sets tempo only if
    /// tempo is sourced from [`TempoSource::Tap`], and moves phase only if phase
    /// is sourced from [`PhaseSource::Tap`]. Tapping along to a MIDI-clocked
    /// tempo to find the downbeat is a real workflow, and so is tapping tempo
    /// while Pro DJ Link owns the downbeat.
    pub fn tap(&mut self, at: f64) -> TapOutcome {
        let new_series = self.tap_tempo.tap(at);
        let bpm = self.tap_tempo.bpm();

        let tempo_applied = match (self.tempo_source, bpm) {
            (TempoSource::Tap, Some(bpm)) => self.set_bpm(TempoSource::Tap, bpm),
            _ => false,
        };

        let phase = if !self.accepts_phase_from(PhaseSource::Tap) {
            Correction::NotAuthoritative
        } else if new_series && !self.running {
            // Counting in a stopped clock: nothing is on screen to stutter, and
            // the operator's first tap is unambiguously the downbeat.
            self.force_downbeat(at);
            Correction::Snapped(0.0)
        } else {
            self.observe_beat(PhaseSource::Tap, at)
        };

        TapOutcome {
            bpm,
            tempo_applied,
            phase,
            taps: self.tap_tempo.len(),
        }
    }

    /// Offers a tempo measured from one audio input.
    ///
    /// The **only** route from [`crate::beat`] into musical time, and the one
    /// place the confidence bar is enforced. Returns whether it was adopted.
    ///
    /// Three independent gates, all of which must pass:
    /// 1. `input` is the configured [`TempoSource::AudioBeat`] input. A second
    ///    enabled input measuring a different tempo cannot steer the clock just
    ///    because it is also running.
    /// 2. The estimate is [`TempoEstimate::is_usable`]. A detector reporting
    ///    "87 BPM, confidence 0.2" is reporting that it does not know, and a
    ///    clock that follows it anyway has turned a hedge into a fact. The
    ///    number should still be *shown* — the operator learns something real
    ///    from watching it wobble — it just must not move the show.
    /// 3. [`Clock::set_bpm`]'s own sanity range.
    ///
    /// Tempo only. The downbeat is [`Clock::observe_audio_beat`] and is gated
    /// separately, because the two are not equally reliable.
    pub fn offer_audio_tempo(&mut self, input: Id, estimate: TempoEstimate) -> bool {
        if !estimate.is_usable() {
            return false;
        }
        self.set_bpm(TempoSource::AudioBeat { input }, estimate.bpm)
    }

    /// Reports a beat detected on one audio input.
    ///
    /// A thin, honest wrapper over [`Clock::observe_beat`]: it refuses a beat
    /// whose own confidence is below [`USABLE_CONFIDENCE`] before the clock's
    /// slew policy ever sees it, because a low-confidence beat is not a noisy
    /// measurement of the right instant — it is frequently a measurement of the
    /// *wrong* instant, and the slew would faithfully drag the whole grid onto
    /// it.
    ///
    /// Deliberately **beat**, never downbeat: see [`crate::beat`] for why
    /// nothing here infers a bar line.
    pub fn observe_audio_beat(&mut self, input: Id, beat: DetectedBeat) -> Correction {
        // Spelled out rather than `!(c >= bar)` so the NaN case is visible:
        // a corrupt confidence must be rejected, and `NaN < bar` is false.
        if !beat.confidence.is_finite() || beat.confidence < USABLE_CONFIDENCE {
            return Correction::Rejected(0.0);
        }
        self.observe_beat(PhaseSource::AudioOnset { input }, beat.at)
    }

    /// The tap estimator, for a count-in display.
    #[must_use]
    pub const fn tap_tempo(&self) -> &TapTempo {
        &self.tap_tempo
    }

    /// Whether `from` is the configured phase authority.
    ///
    /// [`PhaseSource::FollowTempo`] means "whatever phase the tempo transport
    /// carries"; the shell tags those observations `FollowTempo` because the
    /// clock deliberately does not know which transport is behind them.
    #[must_use]
    pub fn accepts_phase_from(&self, from: PhaseSource) -> bool {
        from == self.phase_source
    }

    /// Signed error in beats between the clock's back-projected estimate at `at`
    /// and the nearest multiple of `period`. Positive = the clock is ahead.
    fn error_against_grid(&self, from: PhaseSource, at: f64, period: f64) -> Option<f64> {
        if !self.accepts_phase_from(from) {
            return None;
        }
        let projected = self.beat_at(at)?;
        Some(projected - (projected / period).round() * period)
    }

    /// What the policy makes of an error, deciding nothing and applying nothing.
    ///
    /// Separate from [`Clock::queue`] so a caller that must apply a correction
    /// in parts — [`Clock::observe_downbeat`] — can find out it will be rejected
    /// *before* it has applied any of them.
    fn verdict(&self, error: f64) -> Correction {
        if !error.is_finite() {
            Correction::Rejected(0.0)
        } else if error.abs() > self.slew.max_error_beats {
            Correction::Rejected(error)
        } else if error.abs() < self.slew.deadband_beats {
            Correction::WithinDeadband(error)
        } else {
            Correction::Slewing(error)
        }
    }

    /// Applies the deadband and ceiling, then queues what survives.
    fn queue(&mut self, error: f64) -> Correction {
        let verdict = self.verdict(error);
        if let Correction::Slewing(error) = verdict {
            // Negated: an estimate running *ahead* of the music must be held back.
            self.pending = -error;
        }
        verdict
    }
}

// ─── helpers ─────────────────────────────────────────────────────────────────

fn finite_or(v: f64, fallback: f64) -> f64 {
    if v.is_finite() {
        v
    } else {
        fallback
    }
}

fn sane_bpm(bpm: f64) -> Option<f64> {
    (bpm.is_finite() && (MIN_BPM..=MAX_BPM).contains(&bpm)).then_some(bpm)
}

/// Median of a short slice, by insertion sort into a fixed buffer. Even-length
/// slices take the mean of the middle pair.
fn median_of(values: &[f64]) -> f64 {
    let mut buf = [0.0f64; TAP_CAPACITY];
    let n = values.len().min(TAP_CAPACITY);
    buf[..n].copy_from_slice(&values[..n]);
    for i in 1..n {
        let v = buf[i];
        let mut j = i;
        while j > 0 && buf[j - 1] > v {
            buf[j] = buf[j - 1];
            j -= 1;
        }
        buf[j] = v;
    }
    if n == 0 {
        0.0
    } else if n % 2 == 1 {
        buf[n / 2]
    } else {
        (buf[n / 2 - 1] + buf[n / 2]) / 2.0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn running(bpm: f64) -> Clock {
        let mut c = Clock::new(bpm);
        c.start(0.0);
        c
    }

    fn close(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() <= eps
    }

    // ── advance and phase ───────────────────────────────────────────────────

    #[test]
    fn position_advances_at_tempo() {
        let mut c = running(120.0);
        c.advance_to(1.0);
        assert!(close(c.beat_position(), 2.0, 1e-12));
        c.advance_to(1.5);
        assert!(close(c.beat_position(), 3.0, 1e-12));
    }

    #[test]
    fn an_absolute_monotonic_clock_is_not_dumped_into_beat_zero() {
        // The shell ticks every frame and hands over whatever its monotonic
        // clock says — which on a machine that has been up two hours is a very
        // large number, not a small delta.
        let mut c = Clock::new(120.0);
        assert_eq!(c.advance_to(9_000.0), 0.0, "first tick only seats the epoch");
        assert_eq!(c.advance_to(9_000.5), 0.5, "…and is stopped, so no motion");
        assert_eq!(c.beat_position(), 0.0);
        c.start(9_000.5);
        c.advance_to(9_001.5);
        assert!(close(c.beat_position(), 2.0, 1e-12));
    }

    #[test]
    fn phase_wraps_cleanly_over_many_beats() {
        let mut c = running(128.0);
        // 600 ticks of 1/60 s = 10 s = 21.333… beats at 128 BPM.
        for i in 1..=600 {
            c.advance_to(f64::from(i) / 60.0);
            let p = c.beat_phase();
            assert!((0.0..1.0).contains(&p), "beat phase escaped 0..1: {p}");
            let b = c.bar_phase();
            assert!((0.0..1.0).contains(&b), "bar phase escaped 0..1: {b}");
            assert!(c.beat_in_bar() < 4);
        }
        assert!(close(c.beat_position(), 10.0 * 128.0 / 60.0, 1e-9));
        assert!(close(c.bar_position(), c.beat_position() / 4.0, 1e-12));
    }

    #[test]
    fn beat_in_bar_cycles_with_the_bar() {
        let mut c = running(60.0); // one beat per second
        let seen: Vec<u32> = (0..5)
            .map(|i| {
                c.advance_to(f64::from(i) + 0.5);
                c.beat_in_bar()
            })
            .collect();
        assert_eq!(seen, vec![0, 1, 2, 3, 0]);
    }

    #[test]
    fn stopped_clock_does_not_advance() {
        let mut c = running(120.0);
        c.advance_to(1.0);
        c.stop();
        c.advance_to(5.0);
        assert!(close(c.beat_position(), 2.0, 1e-12));
        // And restarting does not dump the stopped interval in.
        c.start(5.0);
        c.advance_to(5.5);
        assert!(close(c.beat_position(), 3.0, 1e-12));
    }

    #[test]
    fn non_monotonic_time_never_rewinds_the_show() {
        let mut c = running(120.0);
        c.advance_to(2.0);
        let before = c.beat_position();
        assert_eq!(c.advance_to(1.0), 0.0);
        assert_eq!(c.beat_position(), before);
        // The epoch follows the bad timestamp, so the next good one is relative
        // to it rather than replaying the lost second.
        c.advance_to(1.5);
        assert!(close(c.beat_position(), before + 1.0, 1e-12));
    }

    #[test]
    fn non_finite_input_is_ignored() {
        let mut c = running(120.0);
        c.advance_to(1.0);
        c.advance_to(f64::NAN);
        c.advance_by(f64::INFINITY);
        assert!(close(c.beat_position(), 2.0, 1e-12));
    }

    // ── tempo ───────────────────────────────────────────────────────────────

    #[test]
    fn tempo_change_mid_playback_keeps_position_continuous() {
        let mut c = running(120.0);
        c.advance_to(1.75); // 3.5 beats
        assert!(close(c.beat_position(), 3.5, 1e-12));

        assert!(c.set_bpm(TempoSource::Manual, 174.0));
        assert!(
            close(c.beat_position(), 3.5, 1e-12),
            "a tempo change must not move the beat the music is on"
        );

        c.advance_to(2.75); // one more second, now at 174 BPM
        assert!(close(c.beat_position(), 3.5 + 174.0 / 60.0, 1e-12));
    }

    #[test]
    fn tempo_is_only_accepted_from_the_tempo_authority() {
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::MidiClock);
        assert!(!c.set_bpm(TempoSource::Tap, 174.0));
        assert_eq!(c.bpm(), 120.0);
        assert!(c.set_bpm(TempoSource::MidiClock, 174.0));
        assert_eq!(c.bpm(), 174.0);
    }

    #[test]
    fn absurd_tempo_is_rejected_not_clamped() {
        let mut c = Clock::new(120.0);
        for bad in [0.0, -128.0, 5.0, 1_000.0, f64::NAN, f64::INFINITY] {
            assert!(!c.set_bpm(TempoSource::Manual, bad), "accepted {bad}");
        }
        assert_eq!(c.bpm(), 120.0);
    }

    #[test]
    fn a_corrupt_document_tempo_still_opens() {
        assert_eq!(Clock::new(f64::NAN).bpm(), DEFAULT_BPM);
        assert_eq!(Clock::new(0.0).bpm(), DEFAULT_BPM);
    }

    #[test]
    fn config_carries_separable_sources_through() {
        let config = ClockConfig {
            bpm: 128.0,
            tempo_source: TempoSource::AbletonLink,
            phase_source: PhaseSource::ProDjLink,
            quantise: Quantise::Bar,
        };
        let c = Clock::from_config(&config);
        assert_eq!(c.bpm(), 128.0);
        assert_eq!(c.tempo_source(), TempoSource::AbletonLink);
        assert_eq!(c.phase_source(), PhaseSource::ProDjLink);
    }

    // ── separability: the rekordbox case ────────────────────────────────────

    #[test]
    fn link_supplies_tempo_while_pro_dj_link_owns_the_downbeat() {
        // The reason the two axes are separate at all: rekordbox's BPM over Link
        // is usable, its downbeat is not.
        let mut c = Clock::from_config(&ClockConfig {
            bpm: 120.0,
            tempo_source: TempoSource::AbletonLink,
            phase_source: PhaseSource::ProDjLink,
            quantise: Quantise::Bar,
        });
        c.start(0.0);
        c.advance_to(1.0);

        assert!(c.set_bpm(TempoSource::AbletonLink, 128.0));
        assert!(!c.set_bpm(TempoSource::MidiClock, 90.0));
        assert_eq!(c.bpm(), 128.0);

        // A Link beat must not be able to move phase here, however confident it is.
        let from_link = c.observe_beat(PhaseSource::FollowTempo, 0.9);
        assert_eq!(from_link, Correction::NotAuthoritative);
        assert_eq!(c.pending_correction(), 0.0);

        // Pro DJ Link can.
        let from_cdj = c.observe_beat(PhaseSource::ProDjLink, 0.9);
        assert!(from_cdj.changed_phase(), "{from_cdj:?}");
    }

    #[test]
    fn tapping_the_downbeat_while_midi_clock_holds_tempo() {
        // The other half of separability: the operator taps to find "1" without
        // their timing being allowed anywhere near the tempo.
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::MidiClock);
        c.set_phase_source(PhaseSource::Tap);
        c.start(0.0);
        c.advance_to(1.0);

        let out = c.tap(0.93); // 0.14 beats early
        assert!(!out.tempo_applied, "a tap must not steer MIDI-clocked tempo");
        assert_eq!(c.bpm(), 120.0);
        assert!(out.phase.changed_phase(), "{:?}", out.phase);
    }

    // ── quantise ────────────────────────────────────────────────────────────

    #[test]
    fn immediate_quantise_never_waits() {
        let mut c = running(128.0);
        c.advance_to(0.37);
        assert_eq!(c.beats_until(Quantise::Immediate), 0.0);
        assert_eq!(c.seconds_until(Quantise::Immediate), 0.0);
        // A zero-bar wait is not a wait.
        assert_eq!(c.beats_until(Quantise::Bars(0)), 0.0);
    }

    #[test]
    fn quantise_boundary_maths_holds_at_several_tempos() {
        for bpm in [90.0, 120.0, 128.0, 174.0] {
            for elapsed in [0.01, 0.37, 1.0, 2.25, 7.9] {
                let mut c = running(bpm);
                c.advance_to(elapsed);

                let to_beat = c.beats_until(Quantise::Beat);
                assert!(
                    (0.0..=1.0).contains(&to_beat),
                    "{bpm} BPM @ {elapsed}s: beat wait {to_beat}"
                );
                assert!(close(
                    (c.beat_position() + to_beat).fract(),
                    0.0,
                    1e-9
                ) || close((c.beat_position() + to_beat).fract(), 1.0, 1e-9));

                let to_bar = c.beats_until(Quantise::Bar);
                assert!((0.0..=4.0).contains(&to_bar));
                assert!(close((c.beat_position() + to_bar) % 4.0, 0.0, 1e-9));
                assert!(to_bar >= to_beat - 1e-9, "a bar is never sooner than a beat");

                let to_four = c.beats_until(Quantise::Bars(4));
                assert!((0.0..=16.0).contains(&to_four));
                assert!(close((c.beat_position() + to_four) % 16.0, 0.0, 1e-9));

                // Seconds and beats must agree when nothing is being corrected.
                assert!(close(
                    c.seconds_until(Quantise::Bar),
                    to_bar * c.beat_period(),
                    1e-9
                ));
            }
        }
    }

    #[test]
    fn waiting_out_a_quantise_lands_exactly_on_the_boundary() {
        for bpm in [90.0, 128.0, 174.0] {
            let mut c = running(bpm);
            c.advance_to(0.3);
            let wait = c.seconds_until(Quantise::Bar);
            c.advance_to(0.3 + wait);
            assert!(
                close(c.bar_position().fract(), 0.0, 1e-9)
                    || close(c.bar_position().fract(), 1.0, 1e-9),
                "{bpm} BPM landed at bar {}",
                c.bar_position()
            );
        }
    }

    #[test]
    fn sitting_on_a_boundary_fires_immediately() {
        let mut c = running(120.0);
        c.advance_to(2.0); // exactly bar 1
        assert!(close(c.beats_until(Quantise::Beat), 0.0, 1e-9));
        assert!(close(c.beats_until(Quantise::Bar), 0.0, 1e-9));

        // Position is accumulated f64, so "on the bar line" is really a few ULPs
        // past it. Without the boundary tolerance this launch would wait an
        // entire extra bar — the bug an operator reads as "quantise is broken".
        c.advance_by(1e-13);
        assert!(c.beat_position() > 4.0, "the nudge must actually land past the line");
        assert!(close(c.beats_until(Quantise::Bar), 0.0, 1e-9), "{}", c.beats_until(Quantise::Bar));
        assert!(close(c.beats_until(Quantise::Beat), 0.0, 1e-9));

        // A real distance past it still waits, rather than firing twice.
        c.advance_by(1e-6);
        assert!(c.beats_until(Quantise::Bar) > 3.9);
    }

    #[test]
    fn a_launch_scheduled_during_a_correction_still_lands_on_the_bar() {
        // The clock is not running at nominal tempo while it absorbs an error,
        // so `beats / bps` would schedule the launch early — by tens of ms,
        // which at 128 BPM is plainly visible.
        let mut c = running(120.0);
        c.advance_to(1.06);
        assert!(c.observe_beat(PhaseSource::FollowTempo, 1.06).changed_phase());

        let naive = c.beats_until(Quantise::Bar) * c.beat_period();
        let wait = c.seconds_until(Quantise::Bar);
        assert!(
            wait > naive + 0.01,
            "a held-back clock takes longer to reach the bar: {wait} vs {naive}"
        );

        c.advance_by(wait);
        assert!(
            close(c.bar_position(), 1.0, 1e-9),
            "landed at bar {}",
            c.bar_position()
        );

        // And the same holds when the wait is spent frame by frame rather than
        // in one jump, which is how it is actually consumed.
        let mut c = running(120.0);
        c.advance_to(1.06);
        c.observe_beat(PhaseSource::FollowTempo, 1.06);
        let wait = c.seconds_until(Quantise::Bar);
        let frames = (wait * 60.0).round() as i32;
        for i in 1..=frames {
            c.advance_to(1.06 + wait * f64::from(i) / f64::from(frames));
        }
        assert!(
            close(c.bar_position(), 1.0, 1e-9),
            "frame-stepping and one-shot advance must agree exactly; landed at bar {}",
            c.bar_position()
        );
    }

    #[test]
    fn stopped_clock_never_reaches_a_boundary() {
        let mut c = running(120.0);
        c.advance_to(0.3);
        c.stop();
        assert!(c.seconds_until(Quantise::Bar).is_infinite());
        assert_eq!(c.time_of_next(Quantise::Bar), None);
        // Immediate is still immediate — a stopped clock can still fire now.
        assert_eq!(c.seconds_until(Quantise::Immediate), 0.0);
    }

    #[test]
    fn frames_until_uses_the_exact_cadence_not_the_rounded_one() {
        let mut c = running(120.0);
        c.advance_to(1.0); // beat 2 of 4, so half a bar — exactly 1 s — to wait
        // At 30000/1001 fps that is 30000/1001 frames: a value 29.97 cannot give.
        let frames = c.frames_until(Quantise::Bar, Rational::FPS_29_97);
        assert!(close(frames, 30_000.0 / 1_001.0, 1e-9), "{frames}");
        assert!(
            (frames - 29.97).abs() > 1e-6,
            "rounded 29.97 would have given 29.97, not {frames}"
        );
        assert!(close(c.frames_until(Quantise::Bar, Rational::FPS_60), 60.0, 1e-9));
        assert_eq!(c.frames_until(Quantise::Bar, Rational::new(0, 1)), 0.0);
    }

    #[test]
    fn time_of_next_is_an_absolute_timestamp() {
        let mut c = running(120.0);
        c.advance_to(0.3);
        let at = c.time_of_next(Quantise::Bar).expect("epoch is seated");
        assert!(close(at, 2.0, 1e-9));
        // Before any advance there is no epoch to measure from.
        assert_eq!(Clock::new(120.0).time_of_next(Quantise::Bar), None);
    }

    #[test]
    fn bar_length_is_configurable() {
        let mut c = Clock::new(120.0).with_beats_per_bar(3);
        c.start(0.0);
        c.advance_to(0.25); // half a beat
        assert_eq!(c.beats_per_bar(), 3);
        assert!(close(c.beats_until(Quantise::Bar), 2.5, 1e-12));
        assert!(close(c.beats_until(Quantise::Bars(2)), 5.5, 1e-12));
        // Zero is ignored rather than producing a division by zero.
        assert_eq!(Clock::new(120.0).with_beats_per_bar(0).beats_per_bar(), 4);
    }

    // ── beat-synced playback helpers ────────────────────────────────────────

    #[test]
    fn bpm_sync_rate_stretches_a_clip_onto_the_grid() {
        let c = Clock::new(120.0);
        let four_seconds = Rational::new(4, 1);
        // 8 beats at 120 BPM is 4 s — the clip already fits.
        assert!(close(c.bpm_sync_rate(four_seconds, 8), 1.0, 1e-12));
        // 8 beats at 60 BPM is 8 s, so the same clip must run at half speed.
        let slow = Clock::new(60.0);
        assert!(close(slow.bpm_sync_rate(four_seconds, 8), 0.5, 1e-12));
        // Degenerate input leaves the clip alone rather than freezing it.
        assert_eq!(c.bpm_sync_rate(four_seconds, 0), 1.0);
        assert_eq!(c.bpm_sync_rate(Rational::new(0, 1), 8), 1.0);
    }

    #[test]
    fn beats_per_frame_is_exact_at_ntsc() {
        let c = Clock::new(120.0);
        let bpf = c.beats_per_frame(Rational::FPS_29_97);
        assert!(close(bpf, 2.0 * 1_001.0 / 30_000.0, 1e-15));
        assert_eq!(c.beats_per_frame(Rational::new(0, 1)), 0.0);
    }

    #[test]
    fn loop_phase_tracks_the_window_from_the_downbeat() {
        let mut c = running(120.0);
        c.advance_to(1.0); // beat 2.0
        assert!(close(c.loop_phase(4.0), 0.5, 1e-12));
        assert!(close(c.loop_phase(1.0), 0.0, 1e-12));
        assert!(close(c.loop_phase(8.0), 0.25, 1e-12));
        assert_eq!(c.loop_phase(0.0), 0.0);
        assert_eq!(c.loop_phase(f64::NAN), 0.0);

        // Moving the downbeat must move the top of the window with it, or a
        // 1-bar LFO and a 1-bar loop end up disagreeing about where "1" is.
        c.observe_downbeat(PhaseSource::FollowTempo, 1.0);
        assert!(close(c.loop_phase(4.0), 0.0, 1e-12));
        c.advance_to(1.5); // one beat on
        assert!(close(c.loop_phase(4.0), 0.25, 1e-12));
        assert!(close(c.bar_phase(), 0.25, 1e-12), "a 1-bar window is the bar");
    }

    // ── prediction ──────────────────────────────────────────────────────────

    #[test]
    fn prediction_matches_what_actually_happens() {
        let mut c = running(128.0);
        c.advance_to(0.4);
        let predicted = c.beats_after(1.0);
        c.advance_to(1.4);
        assert!(close(c.beat_position(), predicted, 1e-12));
    }

    #[test]
    fn prediction_accounts_for_an_in_flight_correction() {
        let mut c = running(120.0);
        c.advance_to(1.03); // 0.06 beats past beat 2
        let nominal = c.beat_position() + 2.0;
        assert!(c.observe_beat(PhaseSource::FollowTempo, 1.03).changed_phase());

        let predicted = c.beats_after(1.0);
        assert!(
            predicted < nominal,
            "a clock running ahead must predict itself being held back"
        );
        // Stepping there in small increments must agree with the closed form.
        for i in 1..=100 {
            c.advance_to(1.03 + f64::from(i) / 100.0);
        }
        assert!(
            close(c.beat_position(), predicted, 1e-9),
            "predicted {predicted}, arrived at {}",
            c.beat_position()
        );
    }

    #[test]
    fn beat_at_back_projects_into_the_past() {
        let mut c = running(120.0);
        c.advance_to(1.0);
        assert!(close(c.beat_at(0.5).expect("epoch"), 1.0, 1e-12));
        assert!(close(c.beat_at(1.25).expect("epoch"), 2.5, 1e-12));
    }

    // ── corrections ─────────────────────────────────────────────────────────

    #[test]
    fn a_correction_slews_and_never_jumps() {
        let mut c = running(120.0);
        c.advance_to(1.06); // 0.12 beats ahead of beat 2
        let before = c.beat_position();

        let result = c.observe_beat(PhaseSource::FollowTempo, 1.06);
        assert!(close(result.error().expect("measured"), 0.12, 1e-9));
        assert_eq!(
            c.beat_position(),
            before,
            "observing must not move position on the spot"
        );
        assert!(close(c.pending_correction(), -0.12, 1e-9));
    }

    #[test]
    fn slew_converges_monotonically_without_overshoot() {
        let mut c = running(120.0);
        c.advance_to(1.1);
        c.observe_beat(PhaseSource::FollowTempo, 1.1);
        let start = c.pending_correction();
        assert!(start < 0.0);

        let mut previous = start;
        let mut t = 1.1;
        for _ in 0..600 {
            t += 1.0 / 60.0;
            c.advance_to(t);
            let now = c.pending_correction();
            assert!(
                now >= previous - 1e-15,
                "overshot: {previous} -> {now}"
            );
            assert!(now <= 0.0, "changed sign: {now}");
            previous = now;
        }
        assert_eq!(c.pending_correction(), 0.0, "did not settle within 10 s");
    }

    #[test]
    fn slew_settles_quickly_enough_to_be_locked_by_the_next_bars() {
        let mut c = running(128.0);
        c.advance_to(1.0);
        c.observe_beat(PhaseSource::FollowTempo, 1.0 - 0.08);
        let error = c.pending_correction().abs();
        let mut t = 1.0;
        while t < 4.0 {
            t += 1.0 / 60.0;
            c.advance_to(t);
        }
        assert!(
            c.pending_correction().abs() < error * 0.02,
            "3 s should remove ~all of a correction, {} left",
            c.pending_correction()
        );
    }

    #[test]
    fn slew_never_exceeds_the_tempo_deviation_ceiling() {
        let slew = Slew {
            max_rate_ratio: 0.05,
            deadband_beats: 0.0,
            ..Slew::default()
        };
        let mut c = Clock::new(120.0).with_slew(slew);
        c.start(0.0);
        c.advance_to(1.12); // a quarter-beat error, the largest accepted
        c.observe_beat(PhaseSource::FollowTempo, 1.12);
        assert!(close(c.pending_correction(), -0.24, 1e-9));

        let nominal_step = 120.0 / 60.0 / 60.0; // one 60 Hz frame of beats
        let mut t = 1.12;
        let mut previous = c.beat_position();
        for _ in 0..240 {
            t += 1.0 / 60.0;
            c.advance_to(t);
            let step = c.beat_position() - previous;
            previous = c.beat_position();
            assert!(step > 0.0, "musical time must stay monotonic");
            assert!(
                (step - nominal_step).abs() <= nominal_step * 0.05 + 1e-12,
                "warped by {:.4}% in one frame",
                (step / nominal_step - 1.0) * 100.0
            );
        }
    }

    #[test]
    fn detector_latency_is_cancelled_by_the_capture_timestamp() {
        let mut c = running(120.0);
        // Beat 2 happened at t = 1.0; the detector only tells us at t = 1.04.
        c.advance_to(1.04);
        let honest = c.observe_beat(PhaseSource::FollowTempo, 1.0);
        assert!(
            matches!(honest, Correction::WithinDeadband(e) if e.abs() < 1e-9),
            "a correctly stamped beat should need no correction: {honest:?}"
        );

        // Passing "now" instead would have invented 40 ms of phase error.
        let naive = c.observe_beat(PhaseSource::FollowTempo, 1.04);
        assert!(close(naive.error().expect("measured"), 0.08, 1e-9));
    }

    #[test]
    fn detector_jitter_inside_the_deadband_is_ignored() {
        let mut c = running(120.0);
        c.advance_to(1.002); // 0.004 beats — 2 ms of jitter
        let r = c.observe_beat(PhaseSource::FollowTempo, 1.002);
        assert!(matches!(r, Correction::WithinDeadband(_)), "{r:?}");
        assert_eq!(c.pending_correction(), 0.0);
        assert!(!r.changed_phase());
    }

    #[test]
    fn a_wild_detection_is_rejected_rather_than_chased() {
        let mut c = running(120.0);
        c.advance_to(1.2); // 0.4 beats from the nearest beat — a mis-detect
        let r = c.observe_beat(PhaseSource::FollowTempo, 1.2);
        assert!(matches!(r, Correction::Rejected(_)), "{r:?}");
        assert_eq!(c.pending_correction(), 0.0);
    }

    #[test]
    fn correction_error_is_signed_toward_the_nearest_beat() {
        let mut c = running(120.0);
        c.advance_to(1.05); // 0.1 beats past beat 2 — clock is ahead
        assert!(c.observe_beat(PhaseSource::FollowTempo, 1.05).error().unwrap() > 0.0);

        let mut c = running(120.0);
        c.advance_to(0.95); // 0.1 beats short of beat 2 — clock is behind
        assert!(c.observe_beat(PhaseSource::FollowTempo, 0.95).error().unwrap() < 0.0);
    }

    // ── downbeat ────────────────────────────────────────────────────────────

    #[test]
    fn downbeat_rotates_the_bar_without_moving_the_beat_grid() {
        let mut c = running(120.0);
        c.advance_to(1.0); // beat 2.0, i.e. beat 2 of bar 1
        assert_eq!(c.beat_in_bar(), 2);
        let grid = c.beat_position();

        let r = c.observe_downbeat(PhaseSource::FollowTempo, 1.0);
        assert!(r.changed_phase() || matches!(r, Correction::Snapped(_)), "{r:?}");
        assert_eq!(
            c.beat_position(),
            grid,
            "relabelling the bar must not move a single beat"
        );
        assert_eq!(c.beat_in_bar(), 0, "the observed instant is now the downbeat");
        assert_eq!(c.pending_correction(), 0.0, "a whole-beat rotation needs no slew");
    }

    #[test]
    fn downbeat_slews_only_the_fractional_part() {
        let mut c = running(120.0);
        c.advance_to(1.03); // beat 2.06 — two whole beats plus 0.06 into the bar
        let r = c.observe_downbeat(PhaseSource::FollowTempo, 1.03);
        // Nearest bar line is the one 1.94 beats ahead, not the one 2.06 behind.
        assert!(close(r.error().expect("measured"), -1.94, 1e-9), "{r:?}");
        // The whole -2 beats rotate instantly; only the 0.06 of grid error slews.
        assert!(close(c.pending_correction(), -0.06, 1e-9));
        assert_eq!(c.beat_in_bar(), 0);
        assert_eq!(c.beats_per_bar(), 4, "a rotation is not a time-signature change");
    }

    #[test]
    fn downbeat_rotates_the_short_way_round() {
        let mut c = running(120.0);
        c.advance_to(1.5); // beat 3 of 4 — nearer the next bar line than this one
        c.observe_downbeat(PhaseSource::FollowTempo, 1.5);
        assert_eq!(c.beat_in_bar(), 0, "the observed instant became the downbeat");
        // Standing on the new bar line, a bar-quantised launch fires now…
        assert!(close(c.beats_until(Quantise::Bar), 0.0, 1e-9));
        // …and one beat later the next line is three beats out, not seven.
        c.advance_by(0.5);
        assert!(close(c.beats_until(Quantise::Bar), 3.0, 1e-9));
    }

    #[test]
    fn downbeat_from_the_wrong_source_is_refused() {
        let mut c = running(120.0);
        c.set_phase_source(PhaseSource::MidiSpp);
        c.advance_to(1.0);
        assert_eq!(
            c.observe_downbeat(PhaseSource::ProDjLink, 1.0),
            Correction::NotAuthoritative
        );
        assert_eq!(c.beat_in_bar(), 2);
    }

    #[test]
    fn a_rejected_downbeat_relabels_nothing() {
        // A mis-detect is only "ignored" if it is ignored whole. Splitting it
        // into a rotation plus a grid correction and then rejecting only the
        // grid half leaves the bar silently relabelled — and `Rejected` reports
        // no phase change, so the shell never finds out.
        let mut c = running(120.0);
        c.advance_to(0.8); // beat 1.6: 1.6 from this bar line, 0.4 of grid error
        assert_eq!(c.beat_in_bar(), 1);
        let bar_wait = c.beats_until(Quantise::Bar);

        let r = c.observe_downbeat(PhaseSource::FollowTempo, 0.8);
        assert!(matches!(r, Correction::Rejected(_)), "{r:?}");
        assert!(!r.changed_phase());
        assert_eq!(c.pending_correction(), 0.0);
        assert_eq!(c.beat_in_bar(), 1, "a rejected detection rotated the bar");
        assert_eq!(
            c.beats_until(Quantise::Bar),
            bar_wait,
            "a rejected detection moved the bar line"
        );
    }

    #[test]
    fn a_detector_that_lost_its_timestamp_cannot_move_phase() {
        // Back-projection is the whole mechanism; without a usable capture time
        // there is nothing to project to. Treating a non-finite stamp as "now"
        // silently snaps the clock to the nearest beat on garbage input.
        for bad in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let mut c = running(120.0);
            c.advance_to(1.03); // beat 2.06 — well inside the correctable range
            assert_eq!(c.observe_beat(PhaseSource::FollowTempo, bad), Correction::Rejected(0.0));
            assert_eq!(c.pending_correction(), 0.0, "{bad} moved the grid");

            let mut d = running(120.0);
            d.advance_to(1.0); // beat 2.0 — a whole-beat rotation away from "1"
            assert_eq!(
                d.observe_downbeat(PhaseSource::FollowTempo, bad),
                Correction::Rejected(0.0)
            );
            assert_eq!(d.beat_in_bar(), 2, "{bad} rotated the bar");
            assert_eq!(d.pending_correction(), 0.0);
        }
        // And the prediction it is built on has no answer either.
        let mut c = running(120.0);
        c.advance_to(1.0);
        assert_eq!(c.beat_at(f64::NAN), None);
        assert_eq!(c.beat_at(f64::INFINITY), None);
    }

    #[test]
    fn force_downbeat_refuses_while_running() {
        let mut c = running(120.0);
        c.advance_to(1.3);
        assert!(!c.force_downbeat(1.3), "a hard jump mid-show is visible");

        c.stop();
        assert!(c.force_downbeat(1.3));
        assert_eq!(c.beat_in_bar(), 0);
        assert_eq!(c.beat_phase(), 0.0);
        assert_eq!(c.pending_correction(), 0.0);
    }

    #[test]
    fn observing_before_any_advance_has_nothing_to_compare_against() {
        let mut c = Clock::new(120.0);
        c.start(0.0);
        // start() seats the epoch, so this is measurable…
        assert!(c.observe_beat(PhaseSource::FollowTempo, 0.0).error().is_some());
        // …but a clock that was never started or advanced is not.
        let mut fresh = Clock::new(120.0);
        assert_eq!(
            fresh.observe_beat(PhaseSource::FollowTempo, 0.0),
            Correction::NotAuthoritative
        );
    }

    #[test]
    fn reset_returns_to_bar_one_beat_one() {
        let mut c = running(120.0);
        c.advance_to(1.03);
        c.observe_downbeat(PhaseSource::FollowTempo, 1.03);
        c.reset();
        assert_eq!(c.beat_position(), 0.0);
        assert_eq!(c.beat_in_bar(), 0);
        assert_eq!(c.pending_correction(), 0.0);
        assert_eq!(c.bpm(), 120.0, "reset is a position operation, not a tempo one");
    }

    // ── tap tempo ───────────────────────────────────────────────────────────

    #[test]
    fn tap_tempo_needs_two_taps() {
        let mut t = TapTempo::new();
        assert!(t.is_empty());
        assert_eq!(t.bpm(), None);
        t.tap(0.0);
        assert_eq!(t.bpm(), None);
        t.tap(0.5);
        assert!(close(t.bpm().expect("two taps is an interval"), 120.0, 1e-9));
    }

    #[test]
    fn tap_tempo_reads_clean_taps_exactly() {
        let mut t = TapTempo::new();
        for i in 0..6 {
            t.tap(f64::from(i) * 60.0 / 174.0);
        }
        assert!(close(t.bpm().expect("bpm"), 174.0, 1e-9));
    }

    #[test]
    fn tap_tempo_averages_through_human_jitter() {
        // ±12 ms of wobble around 120 BPM — a good operator, not a metronome.
        let jitter = [0.0, 0.012, -0.009, 0.007, -0.011, 0.004, 0.010];
        let mut t = TapTempo::new();
        for (i, j) in jitter.iter().enumerate() {
            t.tap(i as f64 * 0.5 + j);
        }
        let bpm = t.bpm().expect("bpm");
        assert!(close(bpm, 120.0, 1.0), "jitter moved tempo to {bpm}");
    }

    #[test]
    fn tap_tempo_rejects_a_missed_tap() {
        // Intervals of 0.5 s with one doubled: the operator missed a beat.
        // A plain mean would report ~102 BPM; the median filter must not.
        let times = [0.0, 0.5, 1.0, 2.0, 2.5, 3.0, 3.5];
        let mut t = TapTempo::new();
        for &at in &times {
            t.tap(at);
        }
        let bpm = t.bpm().expect("bpm");
        assert!(close(bpm, 120.0, 0.5), "outlier dragged tempo to {bpm}");

        let naive = 60.0 / ((times[6] - times[0]) / 6.0);
        assert!(
            (naive - 120.0).abs() > 15.0,
            "test is pointless unless a plain mean would have failed"
        );
    }

    #[test]
    fn a_gap_starts_a_new_tap_series() {
        let mut t = TapTempo::new();
        for i in 0..4 {
            t.tap(f64::from(i) * 0.5);
        }
        assert_eq!(t.len(), 4);
        // Long silence, then a new count-in at a different tempo.
        assert!(t.tap(60.0));
        assert_eq!(t.len(), 1);
        assert_eq!(t.bpm(), None, "a new series starts from nothing");
        t.tap(60.4);
        assert!(close(t.bpm().expect("bpm"), 150.0, 1e-9));
    }

    #[test]
    fn tap_series_is_bounded_and_tracks_a_tempo_change() {
        let mut t = TapTempo::new();
        // Twelve taps at 100 BPM, then the ring must have discarded the oldest.
        for i in 0..12 {
            t.tap(f64::from(i) * 0.6);
        }
        assert_eq!(t.len(), TAP_CAPACITY);
        assert!(close(t.bpm().expect("bpm"), 100.0, 1e-9));
        assert!(close(t.last().expect("last"), 6.6, 1e-12));
    }

    #[test]
    fn impossible_tap_tempos_are_not_reported() {
        let mut t = TapTempo::new();
        t.tap(0.0);
        t.tap(0.05); // 1200 BPM
        assert_eq!(t.bpm(), None);

        let mut slow = TapTempo::new();
        slow.tap(0.0);
        slow.tap(2.9); // ~20.7 BPM, inside the window but only just
        assert!(slow.bpm().is_some());
        slow.clear();
        assert!(slow.is_empty());
    }

    #[test]
    fn a_non_finite_tap_is_dropped() {
        let mut t = TapTempo::new();
        t.tap(0.0);
        t.tap(f64::NAN);
        assert_eq!(t.len(), 1);
    }

    #[test]
    fn tapping_a_stopped_clock_counts_it_in() {
        let mut c = Clock::new(174.0);
        c.set_tempo_source(TempoSource::Tap);
        c.set_phase_source(PhaseSource::Tap);

        // Four taps at 120 BPM while stopped: a count-in sets tempo and the "1".
        let mut last = TapOutcome {
            bpm: None,
            tempo_applied: false,
            phase: Correction::NotAuthoritative,
            taps: 0,
        };
        for i in 0..4 {
            last = c.tap(f64::from(i) * 0.5);
        }
        assert_eq!(last.taps, 4);
        assert!(last.tempo_applied);
        assert!(close(c.bpm(), 120.0, 1e-9));
        assert_eq!(c.beat_in_bar(), 0, "the count-in defines the downbeat");

        c.start(1.5);
        c.advance_to(2.0);
        assert!(close(c.beat_position(), 1.0, 1e-9));
    }

    #[test]
    fn tapping_a_running_clock_corrects_rather_than_jumps() {
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::Tap);
        c.set_phase_source(PhaseSource::Tap);
        c.start(0.0);
        c.advance_to(1.06);
        let before = c.beat_position();

        let out = c.tap(1.06);
        assert_eq!(c.beat_position(), before, "a tap must not jump a live clock");
        assert!(matches!(out.phase, Correction::Slewing(_)), "{:?}", out.phase);
    }

    #[test]
    fn tap_measures_tempo_even_when_it_does_not_own_it() {
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::MidiClock);
        let out = [0.0, 0.4, 0.8, 1.2].map(|at| c.tap(at));
        let last = out[3];
        assert!(
            close(last.bpm.expect("measured"), 150.0, 1e-9),
            "the estimator should still report what was tapped"
        );
        assert!(!last.tempo_applied);
        assert_eq!(c.bpm(), 120.0);
    }

    // ── policy plumbing ─────────────────────────────────────────────────────

    #[test]
    fn slew_policy_is_sanitised_into_a_safe_range() {
        let s = Slew {
            rate_per_second: f64::NAN,
            deadband_beats: -1.0,
            max_error_beats: 99.0,
            max_rate_ratio: 10.0,
        }
        .sanitised();
        assert_eq!(s.rate_per_second, 2.5);
        assert_eq!(s.deadband_beats, 0.0);
        assert_eq!(s.max_error_beats, 0.5);
        assert!(s.max_rate_ratio <= 0.5, "tempo must stay monotonic");
    }

    #[test]
    fn a_faster_slew_rate_settles_sooner() {
        let settle = |rate: f64| {
            let mut c = Clock::new(120.0).with_slew(Slew {
                rate_per_second: rate,
                max_rate_ratio: 0.5,
                ..Slew::default()
            });
            c.start(0.0);
            c.advance_to(1.1);
            c.observe_beat(PhaseSource::FollowTempo, 1.1);
            let mut t = 1.1;
            while c.pending_correction() != 0.0 && t < 60.0 {
                t += 1.0 / 60.0;
                c.advance_to(t);
            }
            t
        };
        assert!(settle(8.0) < settle(1.0));
    }

    #[test]
    fn median_handles_both_parities() {
        assert!(close(median_of(&[3.0, 1.0, 2.0]), 2.0, 1e-12));
        assert!(close(median_of(&[4.0, 1.0, 3.0, 2.0]), 2.5, 1e-12));
        assert_eq!(median_of(&[]), 0.0);
    }

    // ─── audio tempo and beat gating ─────────────────────────────────────────

    fn audio_estimate(bpm: f64, confidence: f64) -> TempoEstimate {
        TempoEstimate { bpm, confidence }
    }

    #[test]
    fn a_confident_audio_tempo_is_adopted() {
        let input = Id::new(3);
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::AudioBeat { input });
        assert!(c.offer_audio_tempo(input, audio_estimate(128.0, 0.9)));
        assert!((c.bpm() - 128.0).abs() < 1e-12);
    }

    #[test]
    fn a_low_confidence_audio_tempo_is_refused_outright() {
        // The rule the whole beat module exists for: a detector saying "87,
        // confidence 0.2" is saying it does not know. A clock that follows it
        // anyway has turned a hedge into a fact.
        let input = Id::new(3);
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::AudioBeat { input });
        assert!(!c.offer_audio_tempo(input, audio_estimate(87.0, 0.2)));
        assert!((c.bpm() - 120.0).abs() < 1e-12, "tempo must not have moved");
    }

    #[test]
    fn a_tempo_from_a_different_audio_input_cannot_steer_the_clock() {
        // Several inputs are enabled at once by design and they will disagree.
        // Only the configured one is the authority.
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::AudioBeat { input: Id::new(1) });
        assert!(!c.offer_audio_tempo(Id::new(2), audio_estimate(174.0, 0.95)));
        assert!((c.bpm() - 120.0).abs() < 1e-12);
    }

    #[test]
    fn audio_tempo_is_refused_when_tempo_is_owned_by_another_transport() {
        // Tapping or MIDI clock owns tempo; audio detection still measures and
        // still displays, it just does not steer.
        let input = Id::new(1);
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::MidiClock);
        assert!(!c.offer_audio_tempo(input, audio_estimate(128.0, 0.99)));
        assert!((c.bpm() - 120.0).abs() < 1e-12);
    }

    #[test]
    fn an_audio_tempo_outside_the_sane_range_is_still_rejected() {
        // Confidence does not buy a pass on the range check.
        let input = Id::new(1);
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::AudioBeat { input });
        assert!(!c.offer_audio_tempo(input, audio_estimate(1000.0, 0.99)));
        assert!(!c.offer_audio_tempo(input, audio_estimate(f64::NAN, 0.99)));
        assert!((c.bpm() - 120.0).abs() < 1e-12);
    }

    #[test]
    fn a_low_confidence_beat_never_reaches_the_slew_policy() {
        // A weak beat is usually not a noisy measurement of the right instant,
        // it is a measurement of the wrong one — and the slew would faithfully
        // drag the entire grid onto it.
        let input = Id::new(1);
        let mut c = Clock::new(120.0);
        c.set_phase_source(PhaseSource::AudioOnset { input });
        c.start(0.0);
        c.advance_to(1.0);
        let before = c.beat_phase();
        let correction = c.observe_audio_beat(
            input,
            DetectedBeat {
                at: 0.9,
                confidence: 0.3,
            },
        );
        assert!(!correction.changed_phase());
        assert!((c.beat_phase() - before).abs() < 1e-12);
    }

    #[test]
    fn a_confident_beat_from_the_configured_input_corrects_phase() {
        let input = Id::new(1);
        let mut c = Clock::new(120.0);
        c.set_phase_source(PhaseSource::AudioOnset { input });
        c.start(0.0);
        // 120 BPM: beats land every 0.5 s. Report one 0.05 s late.
        c.advance_to(1.05);
        let correction = c.observe_audio_beat(
            input,
            DetectedBeat {
                at: 1.05,
                confidence: 0.95,
            },
        );
        assert!(
            matches!(correction, Correction::Slewing(_)),
            "expected a slew, got {correction:?}"
        );
    }

    #[test]
    fn a_beat_from_an_unconfigured_input_is_not_authoritative() {
        let mut c = Clock::new(120.0);
        c.set_phase_source(PhaseSource::AudioOnset { input: Id::new(1) });
        c.start(0.0);
        c.advance_to(1.0);
        assert_eq!(
            c.observe_audio_beat(
                Id::new(2),
                DetectedBeat {
                    at: 1.0,
                    confidence: 0.99,
                }
            ),
            Correction::NotAuthoritative
        );
    }

    #[test]
    fn audio_tempo_and_audio_phase_stay_independent() {
        // The separation the clock is built around, now reachable from audio:
        // follow the booth feed's tempo while the operator's thumb owns the
        // downbeat. Detecting a BPM must not quietly take over phase too.
        let input = Id::new(1);
        let mut c = Clock::new(120.0);
        c.set_tempo_source(TempoSource::AudioBeat { input });
        c.set_phase_source(PhaseSource::Tap);
        assert!(c.offer_audio_tempo(input, audio_estimate(128.0, 0.9)));
        assert_eq!(
            c.observe_audio_beat(
                input,
                DetectedBeat {
                    at: 1.0,
                    confidence: 0.99,
                }
            ),
            Correction::NotAuthoritative,
            "audio owns tempo here, not phase"
        );
    }
}
