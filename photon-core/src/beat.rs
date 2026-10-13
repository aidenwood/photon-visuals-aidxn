//! Tempo and beat estimation from band energy — **per input, in the core.**
//!
//! Lives here rather than in the macOS shell for the same reason the modulation
//! envelopes do: the Windows shell must get the same number from the same
//! audio, and a second implementation is a second answer. The shell does the
//! FFT (it has the platform's vector maths); this takes the band energies it
//! already produces and nothing else.
//!
//! ## Honesty is the feature
//!
//! A BPM readout that is confidently wrong is worse than a blank one. A VJ
//! glancing at "128" and building the next three minutes on it, when the track
//! is 87 and the detector locked onto a hi-hat, has been actively misled. So:
//!
//! - [`BeatDetector::tempo`] returns `None` until it has genuinely measured
//!   something — [`MIN_COVERAGE`] of the analysis window filled with real
//!   audio, and [`MIN_ESTIMATES`] agreeing passes. Not a seeded 120.
//! - Every estimate carries a [`TempoEstimate::confidence`], computed from
//!   three independent factors (below), and [`TempoEstimate::is_usable`] is the
//!   one place the bar is set.
//! - **Tempo and phase have separate confidences**, because they are not
//!   equally hard. [`BeatDetector::phase`] is routinely much less certain than
//!   the tempo it is derived from, and averaging the two would launder a bad
//!   downbeat behind a good BPM.
//!
//! ## The method
//!
//! 1. **Onset detection function.** Positive spectral flux: per push, the sum
//!    over bands of `max(0, energy - previous energy)`. Rises are events;
//!    falls are not. Using the rise only is what makes a kick read as one
//!    onset rather than two.
//! 2. **Fixed-rate grid.** Flux is written into a ring at [`ODF_RATE`] Hz,
//!    keyed by the *timestamp the shell supplies*, not by push count. Analysis
//!    blocks do not arrive on a perfect cadence and a dropped block must leave
//!    a gap in the right place rather than compressing time.
//! 3. **Autocorrelation.** Over lags from 60/[`MAX_BPM`] to 60/[`MIN_BPM`]
//!    seconds, unbiased (divided by the overlap count, or long lags are
//!    penalised into never winning), on the mean-removed ODF. Autocorrelation
//!    rather than inter-onset-interval histograms because it degrades
//!    gracefully: it still finds the period when half the onsets are missed or
//!    invented, which on a room mic in a loud venue is every second bar.
//! 4. **An octave prior.** Half-time and double-time are both *correct*
//!    answers to "what period repeats" — no signal processing picks between 87
//!    and 174 on its own. Candidates are weighted by a log-normal centred on
//!    [`BeatDetectConfig::preferred_bpm`], which is the operator's knowledge
//!    and the only thing that can break the tie.
//! 5. **Parabolic interpolation** around the winning lag, so the reported BPM
//!    is not quantised to the grid. At 120 BPM one grid sample is about 2.4
//!    BPM, which a VJ would notice as the number stepping.
//! 6. **Phase, separately.** A comb over the ODF at the chosen period picks the
//!    offset that best explains the onsets. Reported with its own confidence
//!    and never adopted automatically.
//!
//! ## What this deliberately does **not** do
//!
//! **No downbeat.** It reports beats, never bar one. Inferring the bar line
//! needs metre and phrase structure, it is a research problem on real club
//! audio, and being confidently a beat out puts every synced clip on the wrong
//! accent in a way that looks intentional. The clock already separates tempo
//! from phase from the bar origin, so an operator can tap the downbeat once
//! over a detected tempo and have both — which is accurate, immediate, and
//! what they already do.
//!
//! ## Cost
//!
//! One pass of flux per push (bands, typically three). The autocorrelation runs
//! at most every [`ESTIMATE_INTERVAL_SECONDS`]: ~230k multiply-adds, four times
//! a second, per input. That is under a millisecond of a single core for a rig
//! with four inputs, which is why detection defaults to on.

use crate::clock::{MAX_BPM, MIN_BPM};
use crate::doc::BeatDetectConfig;

/// Rate of the internal onset-detection grid, Hz.
///
/// 100 Hz is 10 ms per cell — finer than the shell's analysis hop (about 21 ms
/// for a 1024-point window at 48 kHz), so two blocks never collide in one cell,
/// and coarse enough that eight seconds of history is 800 doubles.
pub const ODF_RATE: f64 = 100.0;

/// Seconds of onset history held.
///
/// Eight seconds is sixteen beats at 120 BPM — four bars, enough for
/// autocorrelation to see the period several times over, and short enough that
/// the estimate still follows a DJ pitching a track.
pub const HISTORY_SECONDS: f64 = 8.0;

/// Grid cells held. [`HISTORY_SECONDS`] × [`ODF_RATE`].
const HISTORY: usize = 800;

/// Shortest lag searched, in grid cells. 60/[`MAX_BPM`] seconds.
const MIN_LAG: usize = 15;

/// Longest lag searched, in grid cells. 60/[`MIN_BPM`] seconds.
///
/// Kept below `HISTORY / 2` so every lag has at least half the window of
/// overlap to correlate over; past that the unbiased normalisation is dividing
/// by a handful of samples and reports noise as a strong peak.
const MAX_LAG: usize = 300;

/// How often the autocorrelation runs, seconds.
pub const ESTIMATE_INTERVAL_SECONDS: f64 = 0.25;

/// Fraction of the history window that must contain real audio before any
/// tempo is reported. Four seconds of the eight.
///
/// This is the rule that stops a confident number appearing a quarter of a
/// second after the operator opens an input.
pub const MIN_COVERAGE: f64 = 0.5;

/// Agreeing passes required before the first report.
pub const MIN_ESTIMATES: usize = 3;

/// Confidence at or above which an estimate may steer the clock.
///
/// Deliberately high. Below this the number is still *shown* — an operator
/// watching a readout wobble between 86 and 174 learns something real about
/// the input — but it does not touch musical time.
pub const USABLE_CONFIDENCE: f64 = 0.6;

/// Peak height, in standard deviations above the search range, that carries
/// **no information at all**.
///
/// The tallest of ~286 correlated-but-noisy lags is a few sigma up by chance
/// alone — that is what a maximum *is*, not evidence of a beat. Measured on
/// unstructured input this detector sits at z ≈ 2.0; a genuine click track
/// sits at z ≈ 7–10. The floor goes between them, and anything at or below it
/// scores zero rather than a small positive number.
///
/// Subtracting a floor rather than scaling from zero is the whole point: a
/// plain `z / full` ratio gave pure noise 0.25, which the geometric mean then
/// cube-rooted up into a confidence of 0.63. Chance has to be worth nothing,
/// not a little.
const NOISE_FLOOR_SIGMA: f64 = 3.0;

/// Peak height, in standard deviations, that earns a full peak-to-noise score.
const FULL_CREDIT_SIGMA: f64 = 7.0;

/// Normalised autocorrelation at the winning lag that earns a full strength
/// score.
///
/// Calibrated against measurement, not taste: a synthetic click track reaches
/// 0.54–0.87, unstructured noise still reaches 0.27 (an autocorrelation peak
/// is not small just because it is meaningless). 0.40 sits above the noise and
/// below a clean beat, and leaves messy real audio at r ≈ 0.25 scoring a
/// partial 0.6 — which is the honest answer for a room mic in a loud venue,
/// rather than either a confident 1.0 or a rejection.
const FULL_CREDIT_CORRELATION: f64 = 0.40;

/// Width of the octave prior, in octaves.
///
/// 0.8 is wide enough that a 128 BPM track still reads 128 with the preference
/// left at 120, and narrow enough to break a half/double tie.
const OCTAVE_SIGMA: f64 = 0.8;

/// Estimates kept for the agreement term.
const AGREEMENT_WINDOW: usize = 8;

/// Minimum spacing between estimates entered into the agreement ring, seconds.
///
/// **Not** every pass. Passes run four times a second over an eight-second
/// window, so consecutive ones share 97% of their input and agree with each
/// other almost by definition — measured on pure noise the agreement term read
/// a perfect 1.00. That is not reproducibility, it is window overlap, and a
/// factor that is always 1 contributes nothing while looking like it does.
///
/// At one second apart the eight remembered estimates span a full turnover of
/// the history window, so agreement means "the same answer from substantially
/// different audio". The cost is that the first report arrives around seven
/// seconds in rather than four — which is the correct trade, because the thing
/// being bought is the right to believe the number.
const AGREEMENT_SPACING_SECONDS: f64 = 1.0;

/// Fractional tempo difference counted as "the same estimate".
const AGREEMENT_TOLERANCE: f64 = 0.02;

/// Beats a phase comb tries to explain.
const COMB_TEETH: usize = 8;

/// Per-tooth weight decay in the phase comb — recent beats matter more, because
/// the useful phase is the one the music is on *now*.
const COMB_DECAY: f64 = 0.9;

/// Below this mean ODF the input is treated as silent and nothing is reported.
///
/// Not a noise gate on the audio — the band thresholds do that. This is the
/// difference between "quiet" and "there is no signal here to measure", and
/// reporting a tempo for a disconnected input is the exact failure this module
/// exists to avoid.
const SILENCE_FLOOR: f64 = 1.0e-6;

/// A measured tempo and how much it should be trusted.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TempoEstimate {
    /// Beats per minute. Always within [`MIN_BPM`]..=[`MAX_BPM`].
    pub bpm: f64,
    /// 0–1. The geometric mean of coverage, salience and agreement — see
    /// [`BeatDetector::tempo`].
    pub confidence: f64,
}

impl TempoEstimate {
    /// Whether this estimate is solid enough to steer the clock.
    ///
    /// The single definition of the bar, so the UI's "locked" indicator and the
    /// clock's acceptance rule cannot disagree — which would show an operator a
    /// green light over a tempo that is not actually being followed.
    #[must_use]
    pub fn is_usable(self) -> bool {
        self.confidence >= USABLE_CONFIDENCE
    }
}

/// A measured beat position and how much it should be trusted.
///
/// Separate from [`TempoEstimate`] because the two are not equally reliable and
/// must not be reported as one number.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct PhaseEstimate {
    /// Timestamp of the most recent inferred beat, on the shell's clock.
    ///
    /// Back-dated rather than "now": detection is tens of milliseconds late by
    /// construction, and [`Clock::observe_beat`](crate::clock::Clock::observe_beat)
    /// back-projects its own estimate to the timestamp it is handed. Passing
    /// the time the beat *happened* is what cancels the latency instead of
    /// absorbing it as permanent phase error.
    pub at: f64,
    /// Seconds between beats at the estimated tempo.
    pub period_seconds: f64,
    /// 0–1, and **independent of the tempo confidence it was derived from**.
    pub confidence: f64,
}

impl PhaseEstimate {
    /// Whether this beat is solid enough to correct the clock's phase.
    #[must_use]
    pub fn is_usable(self) -> bool {
        self.confidence >= USABLE_CONFIDENCE
    }
}

/// A beat the detector believes has just happened.
///
/// Emitted by [`BeatDetector::push`] at most once per beat period, so the shell
/// can hand it straight to the clock without having to remember which beats it
/// has already reported. Deduplicating in the shell would mean doing it twice,
/// once per platform, and getting a different answer on each.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DetectedBeat {
    /// When the beat happened, back-dated. See [`PhaseEstimate::at`].
    pub at: f64,
    /// Phase confidence at the moment it was emitted.
    pub confidence: f64,
}

/// Tempo and beat estimation for **one** audio input.
///
/// One per enabled input. They are deliberately independent: a room mic and a
/// booth feed hear different things and are allowed to disagree, and the
/// operator picks which one the clock follows via
/// [`TempoSource::AudioBeat`](crate::doc::TempoSource).
///
/// Holds no clock of its own — every timestamp comes in from the shell, the
/// same rule as [`crate::clock`]. That is what makes a three-hour set
/// reproducible in a unit test.
#[derive(Debug, Clone)]
pub struct BeatDetector {
    config: BeatDetectConfig,

    /// Onset-detection ring at [`ODF_RATE`], oldest-to-newest by `head`.
    odf: Box<[f64; HISTORY]>,
    /// Grid index of the newest written cell, or `None` before the first push.
    head: Option<i64>,
    /// Timestamp of grid index 0.
    epoch: f64,
    /// Grid cells written since the last reset, saturating at [`HISTORY`].
    filled: usize,

    /// Band energies from the previous push, for the flux difference.
    previous: Vec<f64>,

    /// Contiguous, time-ordered copy of `odf`, rebuilt per estimate.
    scratch: Box<[f64; HISTORY]>,
    /// Weighted autocorrelation scores, rebuilt per estimate. Used to *choose*
    /// a lag, never to judge how good it is — see [`Self::salience`].
    scores: Box<[f64; MAX_LAG + 1]>,
    /// Unweighted normalised autocorrelation, rebuilt per estimate. The
    /// evidence.
    raw: Box<[f64; MAX_LAG + 1]>,

    /// Timestamp of the last autocorrelation pass.
    last_estimate_at: Option<f64>,
    /// Recent accepted BPMs, for the agreement term. Spaced by
    /// [`AGREEMENT_SPACING_SECONDS`], not one per pass.
    recent: [f64; AGREEMENT_WINDOW],
    recent_len: usize,
    /// Timestamp of the last estimate entered into `recent`.
    last_remembered_at: Option<f64>,

    tempo: Option<TempoEstimate>,
    phase: Option<PhaseEstimate>,
    /// Predicted time of the next beat to emit.
    next_beat: Option<f64>,
}

impl Default for BeatDetector {
    fn default() -> Self {
        Self::new(BeatDetectConfig::default())
    }
}

impl BeatDetector {
    /// A detector for one input.
    #[must_use]
    pub fn new(config: BeatDetectConfig) -> Self {
        Self {
            config,
            odf: Box::new([0.0; HISTORY]),
            head: None,
            epoch: 0.0,
            filled: 0,
            previous: Vec::new(),
            scratch: Box::new([0.0; HISTORY]),
            scores: Box::new([0.0; MAX_LAG + 1]),
            raw: Box::new([0.0; MAX_LAG + 1]),
            last_estimate_at: None,
            recent: [0.0; AGREEMENT_WINDOW],
            recent_len: 0,
            last_remembered_at: None,
            tempo: None,
            phase: None,
            next_beat: None,
        }
    }

    /// Replaces the configuration.
    ///
    /// Changing [`BeatDetectConfig::preferred_bpm`] does **not** clear the
    /// history: the audio did not change, only which octave of it the operator
    /// wants named, and throwing away eight seconds of onsets to re-derive the
    /// same peak would blank the readout for four seconds for no reason.
    pub fn configure(&mut self, config: BeatDetectConfig) {
        self.config = config;
    }

    /// The configuration in force.
    #[must_use]
    pub const fn config(&self) -> BeatDetectConfig {
        self.config
    }

    /// Forgets everything measured.
    ///
    /// Called when the input's device changes or its bands are edited — the
    /// history describes a signal that no longer exists, and keeping it would
    /// hold a stale tempo on screen through a changeover.
    pub fn reset(&mut self) {
        self.odf.fill(0.0);
        self.head = None;
        self.epoch = 0.0;
        self.filled = 0;
        self.previous.clear();
        self.last_estimate_at = None;
        self.recent_len = 0;
        self.last_remembered_at = None;
        self.tempo = None;
        self.phase = None;
        self.next_beat = None;
    }

    /// Feeds one analysis block's band energies.
    ///
    /// `at` is the timestamp of the block on the shell's clock; `energy` is one
    /// value per band, in the input's band order, **raw** — the same values the
    /// shell pushes to the modulation engine. Smoothed envelopes are the wrong
    /// input here: a release constant long enough to look good on a parameter
    /// fills in the gaps between kicks, which is precisely the structure this
    /// is trying to find.
    ///
    /// Returns a [`DetectedBeat`] on the pushes where a beat is believed to
    /// have just passed, at most once per beat period. Returns `None` the rest
    /// of the time, and always while there is no usable phase.
    ///
    /// A non-finite or backwards `at` is **ignored**, not clamped. A timestamp
    /// that went backwards means the shell got it wrong, and the conservative
    /// answer is the same one [`crate::modulation`] gives a bad frame delta:
    /// freeze, and let the next good one resume.
    pub fn push(&mut self, at: f64, energy: &[f64]) -> Option<DetectedBeat> {
        if !self.config.enabled || !at.is_finite() {
            return None;
        }

        let flux = self.flux(energy);
        self.write(at, flux)?;
        self.maybe_estimate(at);
        self.emit_beat(at)
    }

    /// Positive spectral flux across the bands, advancing the previous frame.
    ///
    /// A band count that changed means the operator edited the input's bands
    /// mid-stream; the difference against the old set is meaningless, so this
    /// push contributes nothing and the next one is measured against it.
    fn flux(&mut self, energy: &[f64]) -> f64 {
        if self.previous.len() != energy.len() {
            self.previous.clear();
            self.previous
                .extend(energy.iter().map(|e| if e.is_finite() { *e } else { 0.0 }));
            return 0.0;
        }
        let mut sum = 0.0;
        for (prev, e) in self.previous.iter_mut().zip(energy) {
            let e = if e.is_finite() { *e } else { 0.0 };
            // Rises only. A fall is the tail of the last event, not a new one,
            // and counting it would put a spurious onset after every hit.
            sum += (e - *prev).max(0.0);
            *prev = e;
        }
        if energy.is_empty() {
            0.0
        } else {
            sum / energy.len() as f64
        }
    }

    /// Writes flux into the grid cell for `at`. `None` if the push is rejected.
    fn write(&mut self, at: f64, flux: f64) -> Option<()> {
        let Some(head) = self.head else {
            self.epoch = at;
            self.head = Some(0);
            self.filled = 1;
            self.odf[0] = flux;
            return Some(());
        };

        let index = ((at - self.epoch) * ODF_RATE).floor();
        if !index.is_finite() {
            return None;
        }
        #[allow(clippy::cast_possible_truncation)]
        let index = index as i64;

        if index < head {
            // Backwards. Ignore rather than rewrite history.
            return None;
        }
        if index == head {
            // Two blocks inside one 10 ms cell. Keep the larger: an onset is a
            // peak, and averaging two blocks halves a transient that landed in
            // only one of them.
            let slot = Self::slot(head);
            self.odf[slot] = self.odf[slot].max(flux);
            return Some(());
        }
        if index - head >= HISTORY as i64 {
            // A gap longer than the whole window — a stopped and restarted
            // input. Nothing measured before it is relevant.
            self.reset();
            self.epoch = at;
            self.head = Some(0);
            self.filled = 1;
            self.odf[0] = flux;
            return Some(());
        }

        // Zero-fill the silence the shell did not report, so a gap stays a gap
        // in time rather than compressing the grid.
        for i in (head + 1)..index {
            self.odf[Self::slot(i)] = 0.0;
        }
        self.odf[Self::slot(index)] = flux;
        self.head = Some(index);
        #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
        let advanced = (index - head) as usize;
        self.filled = (self.filled + advanced).min(HISTORY);
        Some(())
    }

    #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
    fn slot(index: i64) -> usize {
        index.rem_euclid(HISTORY as i64) as usize
    }

    /// Fraction of the analysis window filled with measured audio, 0–1.
    ///
    /// Exposed because it is the honest answer to "why is there no BPM yet",
    /// and a UI that can show a filling bar is better than one that shows
    /// nothing and then a number.
    #[must_use]
    pub fn coverage(&self) -> f64 {
        self.filled as f64 / HISTORY as f64
    }

    /// The current tempo estimate, or `None` if nothing has been measured.
    ///
    /// `None` means **unmeasured**, never "120". The three factors behind
    /// [`TempoEstimate::confidence`], combined as a geometric mean so one bad
    /// factor drags the result down rather than being averaged away:
    ///
    /// | Factor | What it catches |
    /// |---|---|
    /// | coverage | not enough audio yet to have an opinion |
    /// | salience | a flat autocorrelation — no period actually repeats |
    /// | agreement | a peak that moves between passes, i.e. it is noise |
    #[must_use]
    pub const fn tempo(&self) -> Option<TempoEstimate> {
        self.tempo
    }

    /// The current beat-phase estimate, or `None`.
    ///
    /// Always less certain than [`Self::tempo`] and reported separately for
    /// that reason.
    #[must_use]
    pub const fn phase(&self) -> Option<PhaseEstimate> {
        self.phase
    }

    fn maybe_estimate(&mut self, at: f64) {
        if let Some(last) = self.last_estimate_at {
            if at - last < ESTIMATE_INTERVAL_SECONDS {
                return;
            }
        }
        if self.coverage() < MIN_COVERAGE {
            return;
        }
        self.last_estimate_at = Some(at);
        self.estimate(at);
    }

    /// One autocorrelation pass.
    fn estimate(&mut self, now: f64) {
        let Some(head) = self.head else { return };

        // Time-order the ring, mean-removed. Mean removal matters: the ODF is
        // non-negative, so its DC component alone produces a monotonically
        // decaying autocorrelation that swamps every real peak.
        let mut sum = 0.0;
        for i in 0..HISTORY {
            #[allow(clippy::cast_possible_wrap)]
            let v = self.odf[Self::slot(head - (HISTORY as i64 - 1) + i as i64)];
            self.scratch[i] = v;
            sum += v;
        }
        let mean = sum / HISTORY as f64;
        if mean < SILENCE_FLOOR {
            self.clear_estimates();
            return;
        }
        for v in self.scratch.iter_mut() {
            *v -= mean;
        }

        let energy: f64 = self.scratch.iter().map(|v| v * v).sum::<f64>() / HISTORY as f64;
        if energy <= 0.0 || !energy.is_finite() {
            self.clear_estimates();
            return;
        }

        // Unbiased autocorrelation, weighted by the octave prior.
        let mut best_lag = 0usize;
        let mut best = f64::NEG_INFINITY;
        for lag in MIN_LAG..=MAX_LAG {
            let mut acc = 0.0;
            for i in lag..HISTORY {
                acc += self.scratch[i] * self.scratch[i - lag];
            }
            let r = acc / ((HISTORY - lag) as f64 * energy);
            self.raw[lag] = r;
            let score = r.max(0.0) * self.octave_weight(lag as f64);
            self.scores[lag] = score;
            if score > best {
                best = score;
                best_lag = lag;
            }
        }

        if best <= 0.0 || best_lag == 0 {
            self.clear_estimates();
            return;
        }

        let lag = self.interpolate_lag(best_lag);
        let bpm = 60.0 * ODF_RATE / lag;
        if !(MIN_BPM..=MAX_BPM).contains(&bpm) {
            self.clear_estimates();
            return;
        }

        let salience = self.salience(best_lag);
        if salience <= 0.0 {
            self.clear_estimates();
            return;
        }
        let agreement = self.agreement(bpm);
        self.remember(bpm, now);

        if self.recent_len < MIN_ESTIMATES {
            // Measured, but not yet enough passes to say whether it holds.
            // Reporting the first peak as a tempo is exactly how a detector
            // ends up confidently announcing a cough.
            return;
        }

        let confidence = (self.coverage().clamp(0.0, 1.0) * salience * agreement)
            .max(0.0)
            .cbrt();
        self.tempo = Some(TempoEstimate { bpm, confidence });
        self.estimate_phase(now, head, lag, confidence);
    }

    fn clear_estimates(&mut self) {
        self.tempo = None;
        self.phase = None;
        self.next_beat = None;
        self.recent_len = 0;
        self.last_remembered_at = None;
    }

    /// How much the winning lag is actually supported by the audio, 0–1.
    ///
    /// **Measured on the unweighted autocorrelation, never the weighted
    /// scores.** That distinction is the whole function, and getting it wrong
    /// produced exactly the failure this module is written to prevent: the
    /// octave prior is a bell curve over the lag range, so scoring a *flat*
    /// autocorrelation against it yields a tall, smooth, entirely artificial
    /// peak at the preferred tempo. Unstructured noise came out as "93.8 BPM,
    /// confidence 0.76" — a number with no signal behind it whatsoever,
    /// reported confidently enough for a VJ to sync a show to it. The prior is
    /// allowed to *choose* between candidates; it is not allowed to be the
    /// evidence that any of them are real.
    ///
    /// Two independent tests, and the **weaker** one governs, because each
    /// catches a case the other misses:
    ///
    /// - **Peak-to-noise.** How many standard deviations the peak stands above
    ///   the spread of the whole search range. Catches a flat autocorrelation,
    ///   where every lag correlates about as well as every other. On its own it
    ///   is not enough: a very weak but consistent periodicity can still be
    ///   several sigma above a very tight spread.
    /// - **Absolute correlation.** How strongly the signal actually repeats at
    ///   that lag. Catches the opposite case — a statistically clean peak that
    ///   explains almost none of the signal.
    ///
    /// Taking the minimum rather than a product or an average means a single
    /// failed test sets the answer. Averaging would let a strong peak-to-noise
    /// ratio launder a correlation of 0.04, which is how a detector talks
    /// itself into a tempo.
    fn salience(&self, best_lag: usize) -> f64 {
        let count = (MAX_LAG - MIN_LAG + 1) as f64;
        let slice = &self.raw[MIN_LAG..=MAX_LAG];
        let mean = slice.iter().sum::<f64>() / count;
        let variance = slice.iter().map(|r| (r - mean).powi(2)).sum::<f64>() / count;
        let deviation = variance.sqrt();

        let peak = self.raw[best_lag];
        if peak <= 0.0 || !peak.is_finite() {
            return 0.0;
        }

        // A zero spread means every lag correlates identically, which is not a
        // beat however tall the "peak" is.
        let z = if deviation > f64::EPSILON {
            (peak - mean) / deviation
        } else {
            0.0
        };

        let peak_to_noise =
            ((z - NOISE_FLOOR_SIGMA) / (FULL_CREDIT_SIGMA - NOISE_FLOOR_SIGMA)).clamp(0.0, 1.0);
        let strength = (peak / FULL_CREDIT_CORRELATION).clamp(0.0, 1.0);
        peak_to_noise.min(strength)
    }

    /// Log-normal weight on a candidate lag, centred on the operator's
    /// preferred tempo.
    fn octave_weight(&self, lag: f64) -> f64 {
        let preferred = if self.config.preferred_bpm.is_finite() {
            self.config.preferred_bpm.clamp(MIN_BPM, MAX_BPM)
        } else {
            120.0
        };
        let bpm = 60.0 * ODF_RATE / lag;
        let octaves = (bpm / preferred).log2();
        (-0.5 * (octaves / OCTAVE_SIGMA).powi(2)).exp()
    }

    /// Sub-cell refinement of the winning lag.
    ///
    /// Three-point parabolic fit, the standard refinement for a sampled peak.
    /// Without it the reported BPM is quantised to the grid — about 2.4 BPM at
    /// 120 — which reads as the number stepping rather than settling.
    fn interpolate_lag(&self, lag: usize) -> f64 {
        if lag <= MIN_LAG || lag >= MAX_LAG {
            return lag as f64;
        }
        let (a, b, c) = (self.scores[lag - 1], self.scores[lag], self.scores[lag + 1]);
        let denom = a - 2.0 * b + c;
        if denom.abs() < f64::EPSILON {
            return lag as f64;
        }
        let delta = 0.5 * (a - c) / denom;
        if delta.abs() > 1.0 || !delta.is_finite() {
            lag as f64
        } else {
            lag as f64 + delta
        }
    }

    /// Fraction of recent estimates within [`AGREEMENT_TOLERANCE`] of `bpm`.
    fn agreement(&self, bpm: f64) -> f64 {
        if self.recent_len == 0 {
            return 0.0;
        }
        let agreeing = self.recent[..self.recent_len]
            .iter()
            .filter(|b| ((*b - bpm) / bpm).abs() <= AGREEMENT_TOLERANCE)
            .count();
        agreeing as f64 / self.recent_len as f64
    }

    /// Enters an estimate into the agreement ring, no more than once per
    /// [`AGREEMENT_SPACING_SECONDS`].
    fn remember(&mut self, bpm: f64, now: f64) {
        if let Some(last) = self.last_remembered_at {
            if now - last < AGREEMENT_SPACING_SECONDS {
                return;
            }
        }
        self.last_remembered_at = Some(now);
        if self.recent_len == AGREEMENT_WINDOW {
            self.recent.rotate_left(1);
            self.recent_len -= 1;
        }
        self.recent[self.recent_len] = bpm;
        self.recent_len += 1;
    }

    /// Comb over the ODF at the chosen period, picking the offset that best
    /// explains the onsets.
    fn estimate_phase(&mut self, now: f64, head: i64, lag: f64, tempo_confidence: f64) {
        let period = lag.round().max(1.0);
        #[allow(clippy::cast_sign_loss, clippy::cast_possible_truncation)]
        let period_cells = period as usize;
        let teeth = COMB_TEETH.min((HISTORY - 1) / period_cells.max(1)).max(1);

        let mut best = f64::NEG_INFINITY;
        let mut best_offset = 0usize;
        let mut total = 0.0;
        for offset in 0..period_cells {
            let mut score = 0.0;
            let mut weight = 1.0;
            for k in 0..teeth {
                let back = offset + k * period_cells;
                if back >= HISTORY {
                    break;
                }
                // `scratch` is mean-removed and time-ordered, newest last.
                score += self.scratch[HISTORY - 1 - back] * weight;
                weight *= COMB_DECAY;
            }
            total += score.max(0.0);
            if score > best {
                best = score;
                best_offset = offset;
            }
        }

        let average = total / period_cells as f64;
        if best <= 0.0 || !best.is_finite() {
            self.phase = None;
            self.next_beat = None;
            return;
        }
        let sharpness = ((best - average) / (best + average)).clamp(0.0, 1.0);

        // Multiplied, not averaged: a phase derived from a tempo nobody trusts
        // cannot be more trustworthy than that tempo.
        let confidence = sharpness * tempo_confidence;
        let period_seconds = lag / ODF_RATE;
        let newest_cell_time = self.epoch + head as f64 / ODF_RATE;
        let at = newest_cell_time - best_offset as f64 / ODF_RATE;

        self.phase = Some(PhaseEstimate {
            at,
            period_seconds,
            confidence,
        });

        // Re-seat the beat schedule onto the freshly measured phase, one period
        // ahead of the inferred beat, skipping any that are already in the
        // past. A re-seat that landed behind `now` would dump a burst of
        // backdated beats into the clock at once.
        let mut next = at + period_seconds;
        while next <= now {
            next += period_seconds;
        }
        self.next_beat = Some(next);
    }

    /// Emits at most one beat per push, when a predicted beat time has passed.
    fn emit_beat(&mut self, now: f64) -> Option<DetectedBeat> {
        let phase = self.phase?;
        let next = self.next_beat?;
        if now < next {
            return None;
        }
        self.next_beat = Some(next + phase.period_seconds);
        Some(DetectedBeat {
            at: next,
            confidence: phase.confidence,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Feeds a synthetic click track: one band, an impulse on every beat.
    ///
    /// Blocks arrive at a deliberately awkward 21.3 ms — the real hop for a
    /// 1024-point window at 48 kHz — so nothing here can accidentally depend on
    /// pushes lining up with the 10 ms grid.
    const HOP: f64 = 0.021_333_3;

    fn run(detector: &mut BeatDetector, bpm: f64, seconds: f64, start: f64) -> f64 {
        let period = 60.0 / bpm;
        let mut t = start;
        let end = start + seconds;
        let mut next_hit = start;
        while t < end {
            // Energy is high for the one block containing a beat, low otherwise.
            let hit = t >= next_hit && t < next_hit + HOP;
            if hit {
                next_hit += period;
            }
            let e = if hit { 1.0 } else { 0.02 };
            detector.push(t, &[e]);
            t += HOP;
        }
        t
    }

    fn config(preferred: f64) -> BeatDetectConfig {
        BeatDetectConfig {
            enabled: true,
            preferred_bpm: preferred,
        }
    }

    // ── nothing is reported until something is measured ─────────────────────

    #[test]
    fn a_fresh_detector_reports_nothing_not_a_default_tempo() {
        let d = BeatDetector::default();
        assert_eq!(d.tempo(), None, "unmeasured must be None, never 120");
        assert_eq!(d.phase(), None);
        assert_eq!(d.coverage(), 0.0);
    }

    #[test]
    fn one_second_of_audio_is_not_enough_to_claim_a_tempo() {
        let mut d = BeatDetector::default();
        run(&mut d, 128.0, 1.0, 0.0);
        assert!(d.coverage() < MIN_COVERAGE);
        assert_eq!(d.tempo(), None, "a quarter of a window is not a measurement");
    }

    #[test]
    fn silence_reports_no_tempo_however_long_it_lasts() {
        // A disconnected input. A tempo here would be pure invention.
        let mut d = BeatDetector::default();
        let mut t = 0.0;
        while t < 12.0 {
            d.push(t, &[0.0]);
            t += HOP;
        }
        assert!(d.coverage() > MIN_COVERAGE, "the window did fill");
        assert_eq!(d.tempo(), None);
    }

    #[test]
    fn a_disabled_detector_measures_nothing() {
        let mut d = BeatDetector::new(BeatDetectConfig {
            enabled: false,
            preferred_bpm: 120.0,
        });
        run(&mut d, 128.0, 12.0, 0.0);
        assert_eq!(d.tempo(), None);
        assert_eq!(d.coverage(), 0.0);
    }

    // ── it actually finds the tempo ─────────────────────────────────────────

    #[test]
    fn a_steady_click_track_is_measured_within_two_percent() {
        for bpm in [90.0, 120.0, 128.0, 140.0] {
            let mut d = BeatDetector::new(config(120.0));
            run(&mut d, bpm, 14.0, 0.0);
            let t = d.tempo().unwrap_or_else(|| panic!("no tempo at {bpm}"));
            let error = (t.bpm - bpm).abs() / bpm;
            assert!(error < 0.02, "{bpm} read as {} ({error:.3})", t.bpm);
            assert!(t.is_usable(), "{bpm} confidence {:.2}", t.confidence);
        }
    }

    #[test]
    fn the_reported_tempo_is_not_quantised_to_the_grid() {
        // Without parabolic interpolation the nearest representable tempos
        // around 128 are 127.7 and 130.4, and the readout would step.
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 133.0, 14.0, 0.0);
        let t = d.tempo().expect("tempo");
        assert!((t.bpm - 133.0).abs() < 2.0, "read {}", t.bpm);
        assert!(
            t.bpm.fract() != 0.0 || (t.bpm - 133.0).abs() < 0.5,
            "a grid-quantised answer would land on a cell boundary"
        );
    }

    // ── the octave prior is the only thing that can break a half/double tie ──

    #[test]
    fn the_preferred_tempo_picks_the_octave_without_forcing_it() {
        // Same audio, two operators. 174 and 87 are both correct answers to
        // "what period repeats"; the prior is what names the one they mean.
        let mut fast = BeatDetector::new(config(174.0));
        run(&mut fast, 174.0, 14.0, 0.0);
        let f = fast.tempo().expect("fast tempo");
        assert!((f.bpm - 174.0).abs() / 174.0 < 0.03, "read {}", f.bpm);

        let mut slow = BeatDetector::new(config(87.0));
        run(&mut slow, 174.0, 14.0, 0.0);
        let s = slow.tempo().expect("slow tempo");
        assert!(
            (s.bpm - 87.0).abs() / 87.0 < 0.03,
            "the same audio should read 87 for an operator expecting 87, read {}",
            s.bpm
        );
    }

    #[test]
    fn a_preference_does_not_override_the_audio() {
        // The prior weights candidates; it must not manufacture one. A 128 BPM
        // track must still read 128 with the default 120 preference.
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 14.0, 0.0);
        let t = d.tempo().expect("tempo");
        assert!((t.bpm - 128.0).abs() < 3.0, "read {}", t.bpm);
    }

    #[test]
    fn a_nonsense_preference_does_not_poison_the_estimate() {
        let mut d = BeatDetector::new(BeatDetectConfig {
            enabled: true,
            preferred_bpm: f64::NAN,
        });
        run(&mut d, 128.0, 14.0, 0.0);
        let t = d.tempo().expect("tempo");
        assert!(t.bpm.is_finite() && (t.bpm - 128.0).abs() < 5.0, "read {}", t.bpm);
    }

    // ── confidence is honest ────────────────────────────────────────────────

    #[test]
    fn unstructured_noise_is_reported_as_low_confidence_or_not_at_all() {
        // The failure this whole module is written around: a number that looks
        // like a measurement but is not one.
        let mut d = BeatDetector::new(config(120.0));
        let mut t = 0.0;
        let mut seed = 0x1234_5678_u64;
        while t < 14.0 {
            seed = seed
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            let e = (seed >> 33) as f64 / (1u64 << 31) as f64;
            d.push(t, &[e]);
            t += HOP;
        }
        match d.tempo() {
            None => {}
            Some(t) => assert!(
                !t.is_usable(),
                "noise reported as a usable {:.1} BPM at confidence {:.2}",
                t.bpm,
                t.confidence
            ),
        }
    }

    #[test]
    fn confidence_is_never_outside_zero_to_one() {
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 20.0, 0.0);
        let t = d.tempo().expect("tempo");
        assert!((0.0..=1.0).contains(&t.confidence), "{}", t.confidence);
        if let Some(p) = d.phase() {
            assert!((0.0..=1.0).contains(&p.confidence), "{}", p.confidence);
        }
    }

    #[test]
    fn phase_confidence_never_exceeds_the_tempo_confidence_it_came_from() {
        // A downbeat cannot be more trustworthy than the tempo it is placed on.
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 16.0, 0.0);
        let t = d.tempo().expect("tempo");
        let p = d.phase().expect("phase");
        assert!(p.confidence <= t.confidence + 1e-12);
    }

    // ── phase and beat emission ─────────────────────────────────────────────

    #[test]
    fn beats_are_emitted_about_once_per_period_and_never_twice() {
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 120.0, 14.0, 0.0);
        assert!(d.tempo().is_some(), "needs a tempo first");

        let mut beats = Vec::new();
        let mut t = 14.0;
        let period = 0.5;
        let mut next_hit = 14.0;
        while t < 24.0 {
            let hit = t >= next_hit && t < next_hit + HOP;
            if hit {
                next_hit += period;
            }
            if let Some(b) = d.push(t, &[if hit { 1.0 } else { 0.02 }]) {
                beats.push(b.at);
            }
            t += HOP;
        }
        assert!(beats.len() >= 15, "expected ~20 beats in 10 s, got {}", beats.len());
        for w in beats.windows(2) {
            let gap = w[1] - w[0];
            assert!(gap > 0.0, "beats must advance");
            assert!(gap < 1.5, "a 120 BPM beat gap of {gap:.2}s is a missed emission");
        }
    }

    #[test]
    fn an_emitted_beat_is_back_dated_rather_than_stamped_now() {
        // Detection is late by construction; handing the clock "now" would bake
        // that latency in as permanent phase error.
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 120.0, 14.0, 0.0);
        let mut t = 14.0;
        let mut next_hit = 14.0;
        while t < 20.0 {
            let hit = t >= next_hit && t < next_hit + HOP;
            if hit {
                next_hit += 0.5;
            }
            if let Some(b) = d.push(t, &[if hit { 1.0 } else { 0.02 }]) {
                assert!(b.at <= t, "a beat cannot be in the future");
                return;
            }
            t += HOP;
        }
        panic!("no beat emitted");
    }

    #[test]
    fn no_beats_are_emitted_without_a_phase() {
        let mut d = BeatDetector::default();
        for i in 0..100 {
            assert_eq!(d.push(f64::from(i) * HOP, &[0.0]), None);
        }
    }

    // ── bad input cannot break it ───────────────────────────────────────────

    #[test]
    fn a_backwards_timestamp_is_ignored_not_absorbed() {
        let mut d = BeatDetector::new(config(120.0));
        let end = run(&mut d, 128.0, 14.0, 0.0);
        let before = d.tempo().expect("tempo");
        d.push(end - 5.0, &[1.0]);
        d.push(f64::NAN, &[1.0]);
        d.push(f64::INFINITY, &[1.0]);
        let after = d.tempo().expect("tempo must survive bad timestamps");
        assert_eq!(before.bpm, after.bpm);
    }

    #[test]
    fn non_finite_energy_is_treated_as_zero() {
        let mut d = BeatDetector::new(config(120.0));
        let mut t = 0.0;
        while t < 10.0 {
            d.push(t, &[f64::NAN]);
            t += HOP;
        }
        assert_eq!(d.tempo(), None, "NaN energy must not become a tempo");
    }

    #[test]
    fn changing_the_band_count_does_not_produce_a_phantom_onset() {
        // Editing an input's bands mid-stream. Differencing three energies
        // against one would register as a huge flux spike.
        let mut d = BeatDetector::new(config(120.0));
        d.push(0.0, &[0.1]);
        d.push(HOP, &[0.9, 0.9, 0.9]);
        // The push with the new band count contributes nothing; the next one is
        // measured against it. Nothing to assert beyond "it did not panic and
        // did not invent a tempo from two pushes".
        assert_eq!(d.tempo(), None);
    }

    #[test]
    fn a_long_gap_restarts_rather_than_compressing_time() {
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 14.0, 0.0);
        assert!(d.tempo().is_some());
        // The input was stopped for a minute and reopened.
        d.push(80.0, &[0.5]);
        assert_eq!(d.coverage(), 1.0 / HISTORY as f64);
        assert_eq!(d.tempo(), None, "nothing before the gap describes this signal");
    }

    #[test]
    fn two_blocks_inside_one_grid_cell_keep_the_louder() {
        // Averaging would halve a transient that landed in only one of them.
        let mut d = BeatDetector::new(config(120.0));
        d.push(0.0, &[0.0]);
        d.push(0.001, &[1.0]);
        d.push(0.002, &[0.0]);
        assert_eq!(d.coverage(), 1.0 / HISTORY as f64, "still one cell");
    }

    #[test]
    fn reset_clears_everything_measured() {
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 14.0, 0.0);
        assert!(d.tempo().is_some());
        d.reset();
        assert_eq!(d.tempo(), None);
        assert_eq!(d.phase(), None);
        assert_eq!(d.coverage(), 0.0);
    }

    #[test]
    fn changing_the_preferred_tempo_does_not_blank_the_readout() {
        // The audio did not change, only which octave of it the operator wants
        // named. Clearing would leave four seconds of blank mid-set.
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 14.0, 0.0);
        let coverage = d.coverage();
        d.configure(config(174.0));
        assert_eq!(d.coverage(), coverage);
        assert!(d.tempo().is_some());
    }

    #[test]
    fn a_tempo_outside_the_clocks_range_is_never_reported() {
        let mut d = BeatDetector::new(config(120.0));
        run(&mut d, 128.0, 14.0, 0.0);
        let t = d.tempo().expect("tempo");
        assert!((MIN_BPM..=MAX_BPM).contains(&t.bpm));
    }

    // ── the octave prior must not manufacture its own evidence ─────────────

    #[test]
    fn a_flat_autocorrelation_is_not_salient_however_the_prior_is_shaped() {
        // The regression this guards. Salience was once computed on the
        // *weighted* scores, so the prior's bell curve over the lag range
        // produced a tall smooth peak at the preferred tempo out of a
        // completely flat autocorrelation. Unstructured noise came out as
        // "93.8 BPM, confidence 0.76".
        //
        // Moving the preference must move which candidate wins and must NOT
        // change how believable the answer is, because the audio has not
        // changed. If a detector reports a usable tempo here under any
        // preference, the prior is being treated as evidence again.
        for preferred in [87.0, 120.0, 174.0] {
            let mut d = BeatDetector::new(config(preferred));
            let mut t = 0.0;
            let mut seed = 0xDEAD_BEEF_u64;
            while t < 14.0 {
                seed = seed
                    .wrapping_mul(6_364_136_223_846_793_005)
                    .wrapping_add(1_442_695_040_888_963_407);
                let e = (seed >> 33) as f64 / (1u64 << 31) as f64;
                d.push(t, &[e]);
                t += HOP;
            }
            if let Some(est) = d.tempo() {
                assert!(
                    !est.is_usable(),
                    "noise read as a usable {:.1} BPM (confidence {:.2}) \
                     with the preference at {preferred}",
                    est.bpm,
                    est.confidence
                );
            }
        }
    }

    #[test]
    fn a_steady_tone_with_no_rhythm_is_not_a_tempo() {
        // Constant energy: the flux is zero everywhere, so there is nothing to
        // correlate. A hum on an open input must not become a BPM.
        let mut d = BeatDetector::new(config(120.0));
        let mut t = 0.0;
        while t < 14.0 {
            d.push(t, &[0.5]);
            t += HOP;
        }
        assert_eq!(d.tempo(), None);
    }

    #[test]
    fn the_preference_moves_the_answer_but_not_the_confidence_much() {
        // The complement of the regression above: on audio that genuinely has
        // a beat, naming a different octave should give a different BPM at a
        // comparable confidence — the evidence is the same evidence.
        let mut a = BeatDetector::new(config(174.0));
        run(&mut a, 174.0, 14.0, 0.0);
        let mut b = BeatDetector::new(config(87.0));
        run(&mut b, 174.0, 14.0, 0.0);
        let (ea, eb) = (a.tempo().expect("fast"), b.tempo().expect("slow"));
        assert!((ea.bpm - 174.0).abs() / 174.0 < 0.03);
        assert!((eb.bpm - 87.0).abs() / 87.0 < 0.03);
        assert!(
            (ea.confidence - eb.confidence).abs() < 0.35,
            "same audio, wildly different confidence: {:.2} vs {:.2}",
            ea.confidence,
            eb.confidence
        );
    }
}
