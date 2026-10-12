// Audio analysis — the signal behind audio-reactive visuals.
//
// Produces band envelopes the modulation system binds to parameters. Beat sync,
// audio reactivity and MIDI are one mechanism in `photon-core`; this is the
// platform side that feeds it.
//
// ## Threading, per `docs/thread-qos-map.md`
//
//  - Capture runs on the OS audio callback thread, which is **genuinely
//    realtime**: no allocation, no locks, no logging. It copies into a
//    preallocated ring and returns.
//  - Analysis (FFT, envelopes) runs at `.userInitiated` with reused scratch.
//  - The render thread samples a **lock-free snapshot** once per frame.
//
// Those three must never block each other. An audio glitch is survivable; a
// render-thread stall is a dropped frame on the program output.
//
// ## Why envelopes rather than raw FFT
//
// A raw bin reading jitters frame to frame and looks like noise when bound to
// opacity. Attack/release smoothing is what makes it read as *musical* rather
// than twitchy — and the attack and release want different constants, because
// a hit should be instant and the decay should not.

import Accelerate
import AVFoundation
import Foundation

/// One frequency band with its own smoothing.
public struct AudioBand: Sendable {
    public var name: String
    public var lowHz: Float
    public var highHz: Float
    /// Rise time, milliseconds. Short, so a hit lands on the frame it happens.
    public var attackMs: Float
    /// Fall time, milliseconds. Longer, or the output flickers.
    public var releaseMs: Float
    /// Below this the band reads zero — stops room noise animating everything.
    public var threshold: Float
    /// Multiplier applied before smoothing.
    public var gain: Float

    public init(name: String, lowHz: Float, highHz: Float,
                attackMs: Float = 5, releaseMs: Float = 180,
                threshold: Float = 0.02, gain: Float = 1) {
        self.name = name
        self.lowHz = lowHz
        self.highHz = highHz
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.threshold = threshold
        self.gain = gain
    }

    /// The three bands every VJ tool ships, as a starting point.
    public static let defaults: [AudioBand] = [
        AudioBand(name: "Low",  lowHz: 20,   highHz: 250,   releaseMs: 220),
        AudioBand(name: "Mid",  lowHz: 250,  highHz: 2000),
        AudioBand(name: "High", lowHz: 2000, highHz: 16000, releaseMs: 120),
    ]
}

/// A lock-free snapshot of the current analysis.
public struct AudioSnapshot: Sendable {
    /// Smoothed level per band, 0...1.
    public var levels: [Float]
    /// Band energy **before** smoothing, same order as `levels`.
    ///
    /// This is what goes to `photon-core`'s modulation, because the attack and
    /// release live there, with the binding, so they are shared with the
    /// Windows shell. Smoothing on both sides is not twice as smooth — it is
    /// laggy and mushy, and it gets blamed on the audio interface.
    ///
    /// `levels` keeps the smoothed values, which is what a meter should show.
    public var rawLevels: [Float] = []
    /// Broadband RMS, 0...1.
    public var rms: Float
    /// Monotonic counter, so a consumer can tell a stale snapshot from a quiet one.
    public var generation: UInt64

    public static let silent = AudioSnapshot(levels: [], rawLevels: [], rms: 0, generation: 0)
}

/// Computes band envelopes from PCM.
///
/// Deliberately separable from live capture: `process(samples:sampleRate:)` is
/// pure, so the analysis can be tested with synthetic signals instead of
/// requiring a microphone and a human listening.
public final class AudioAnalyser: @unchecked Sendable {
    /// Power-of-two window. 1024 at 48 kHz ≈ 21 ms — fine enough to catch a
    /// kick, coarse enough not to jitter.
    public static let fftSize = 1024

    /// Maps summed band energy into roughly 0...1 for a full-scale tone.
    /// Calibrated against a 0.8-amplitude sine; `AudioBand.gain` trims per band.
    static let energyScale: Float = 1.6

    private var bands: [AudioBand]
    private var envelopes: [Float]
    private var setup: vDSP.FFT<DSPSplitComplex>
    private var window: [Float]
    private var realBuf: [Float]
    private var imagBuf: [Float]
    private var magnitudes: [Float]
    private var generation: UInt64 = 0

    /// Current snapshot. Safe to read from the render thread.
    public private(set) var snapshot: AudioSnapshot = .silent

    public init(bands: [AudioBand] = AudioBand.defaults) {
        self.bands = bands
        self.envelopes = [Float](repeating: 0, count: bands.count)
        let log2n = vDSP_Length(log2(Float(Self.fftSize)))
        self.setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self)!
        // Hann window: a rectangular window smears a pure tone across bins,
        // which would make band separation look broken when it isn't.
        self.window = vDSP.window(ofType: Float.self,
                                  usingSequence: .hanningDenormalized,
                                  count: Self.fftSize, isHalfWindow: false)
        self.realBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        self.imagBuf = [Float](repeating: 0, count: Self.fftSize / 2)
        self.magnitudes = [Float](repeating: 0, count: Self.fftSize / 2)
    }

    /// Analyses one window of mono PCM and advances the envelopes.
    ///
    /// `dt` is the time this window represents, used for the smoothing; passing
    /// a non-positive value **freezes** the envelopes rather than snapping them,
    /// for the same reason the modulation engine does: no time passed, so the
    /// filter must not move.
    @discardableResult
    public func process(samples: [Float], sampleRate: Float, dt: Float) -> AudioSnapshot {
        guard samples.count >= Self.fftSize, sampleRate > 0 else { return snapshot }

        var windowed = [Float](repeating: 0, count: Self.fftSize)
        vDSP.multiply(Array(samples.prefix(Self.fftSize)), window, result: &windowed)

        // Pack real input into split-complex form for the real-to-complex FFT.
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: Self.fftSize / 2) { c in
                realBuf.withUnsafeMutableBufferPointer { re in
                    imagBuf.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        vDSP_ctoz(c, 2, &split, 1, vDSP_Length(Self.fftSize / 2))
                    }
                }
            }
        }
        realBuf.withUnsafeMutableBufferPointer { re in
            imagBuf.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                setup.forward(input: split, output: &split)
                vDSP.absolute(split, result: &magnitudes)
            }
        }

        // Normalise: FFT magnitude scales with window length.
        let norm = 2.0 / Float(Self.fftSize)
        vDSP.multiply(norm, magnitudes, result: &magnitudes)

        let binHz = sampleRate / Float(Self.fftSize)
        var levels = [Float](repeating: 0, count: bands.count)
        var raw = [Float](repeating: 0, count: bands.count)

        for (i, band) in bands.enumerated() {
            let lo = max(1, Int(band.lowHz / binHz))
            let hi = min(magnitudes.count - 1, Int(band.highHz / binHz))
            guard hi >= lo else { continue }

            // **Energy in the band, not the mean of its bins.** The mean
            // penalises width: the high band spans ~300 bins and the low band
            // ~5, so a pure tone would average to nearly nothing in one and
            // read strongly in the other. Summing makes a given tone read
            // comparably wherever it sits, and genuinely broadband content read
            // higher — which is what an operator expects.
            var sum: Float = 0
            for b in lo...hi { sum += magnitudes[b] }
            var level = sum * band.gain * Self.energyScale
            level = level < band.threshold ? 0 : min(level, 1)
            raw[i] = level

            // Asymmetric smoothing: fast attack, slow release.
            let tau = level > envelopes[i] ? band.attackMs : band.releaseMs
            let alpha = Self.onePole(tauMs: tau, dt: dt)
            envelopes[i] += (level - envelopes[i]) * alpha
            levels[i] = envelopes[i]
        }

        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(min(samples.count, Self.fftSize)))

        generation &+= 1
        snapshot = AudioSnapshot(levels: levels, rawLevels: raw,
                                 rms: min(rms * 2, 1), generation: generation)
        return snapshot
    }

    /// One-pole smoothing coefficient.
    ///
    /// A non-positive or non-finite `dt` returns **0** (freeze), never 1
    /// (snap) — the same correction the review found in `photon-core`: a bad
    /// time constant meaning "instant" is right, a bad frame delta meaning
    /// "instant" is backwards.
    public static func onePole(tauMs: Float, dt: Float) -> Float {
        guard dt.isFinite, dt > 0 else { return 0 }
        guard tauMs.isFinite, tauMs > 0 else { return 1 }
        return 1 - exp(-dt / (tauMs / 1000))
    }

    /// Band definitions, for a UI to label the levels.
    public var bandNames: [String] { bands.map(\.name) }

    /// Replaces the band set.
    ///
    /// Exists because the **core** decides which bands matter — they come from
    /// whatever the operator has bound — and there is no point running a filter
    /// bank nobody reads. Envelopes reset, since a band's history means nothing
    /// once its frequency range has changed.
    public func setBands(_ newBands: [AudioBand]) {
        bands = newBands
        envelopes = [Float](repeating: 0, count: newBands.count)
        snapshot = .silent
    }

    /// The frequency ranges currently analysed, for comparing against the core.
    public var bandRanges: [(low: Float, high: Float)] {
        bands.map { ($0.lowHz, $0.highHz) }
    }
}
