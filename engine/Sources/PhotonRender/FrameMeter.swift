// Frame measurement — what the telemetry readout is allowed to claim.
//
// Three numbers, three different clocks, three different threads:
//
//  - **CPU ms** is produced and consumed on the render thread alone, so it
//    needs no synchronisation at all.
//  - **GPU ms** arrives on a Metal completion handler, off the frame path.
//  - **Output FPS** arrives on a drawable presentation handler, also off the
//    frame path, and is the only one that reflects what the *display* did
//    rather than what we asked it to do.
//
// Two rules shape every line below, both from `docs/scaffold.md`:
//
//  1. **The render thread never waits on telemetry.** The cross-thread half of
//     this type is read with `withLockIfAvailable`; if a handler happens to
//     hold the lock, the frame keeps its previous published numbers and moves
//     on. There is no path here that blocks presentation.
//  2. **A counter that cannot observe a condition must not report zero for
//     it.** Every metric is optional. "No samples yet", "this drawable was
//     never presented" and "this path has no GPU work" all read as *nil*, and
//     the UI renders them as "—". A telemetry panel that invents a plausible
//     number is worse than a blank one, because a blank one sends you looking.

import Foundation
import Metal
import QuartzCore
import os

/// One published set of frame measurements. Every field is optional because
/// every field has a real state in which it is unknown.
public struct FrameSample: Sendable, Equatable {
    /// Mean CPU milliseconds spent building and submitting a frame, over the
    /// averaging window. `nil` before the first complete frame.
    public var cpuMilliseconds: Double?
    /// Mean GPU milliseconds per frame, from `gpuEndTime - gpuStartTime` on
    /// completed command buffers. `nil` until the first buffer completes.
    public var gpuMilliseconds: Double?
    /// Frames per second derived from *presented* frame intervals. `nil` until
    /// two consecutive frames have both reported a presentation time.
    public var outputFPS: Double?
    /// Median interval between frames, in milliseconds. This is wall-clock
    /// cadence, **not** CPU cost — a frame can be cheap and still be late.
    public var frameIntervalP50: Double?
    /// 99th-percentile frame interval. `nil` below `percentileFloor` samples,
    /// where a "1 in 100" figure would just be the worst of a handful.
    public var frameIntervalP99: Double?
    /// Frames composited that the display never showed, since startup.
    public var unpresentedFrames: Int = 0

    public init(cpuMilliseconds: Double? = nil, gpuMilliseconds: Double? = nil,
                outputFPS: Double? = nil, frameIntervalP50: Double? = nil,
                frameIntervalP99: Double? = nil, unpresentedFrames: Int = 0) {
        self.cpuMilliseconds = cpuMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.outputFPS = outputFPS
        self.frameIntervalP50 = frameIntervalP50
        self.frameIntervalP99 = frameIntervalP99
        self.unpresentedFrames = unpresentedFrames
    }
}

/// A fixed-capacity rolling window with an O(1) mean.
///
/// `sum` is maintained incrementally and **recomputed on every wrap**. Over a
/// long show an incrementally-updated float sum drifts; a full recompute once
/// per `capacity` samples costs nothing measurable and keeps the mean exact to
/// the precision of a single pass.
///
/// Public so the averaging maths can be verified without a GPU — this is the
/// piece every displayed number passes through, and it is the piece where a
/// quiet arithmetic bug would read as a plausible measurement.
public struct FrameRing: Sendable {
    public let capacity: Int
    public private(set) var values: [Double] = []
    private var next = 0
    private var sum = 0.0

    public init(capacity: Int) { self.capacity = capacity }

    public var count: Int { values.count }

    /// Adds a sample. **Non-finite and negative values are discarded, not
    /// clamped.** A NaN frame time is a failed measurement; folding it in as
    /// zero would report a frame that cost nothing, and folding it in as-is
    /// would turn the mean into NaN for the rest of the window.
    public mutating func append(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        if values.count < capacity {
            values.append(value)
            sum += value
            return
        }
        sum += value - values[next]
        values[next] = value
        next += 1
        if next >= capacity {
            next = 0
            // One exact pass per wrap, so incremental drift never accumulates.
            sum = values.reduce(0, +)
        }
    }

    /// Mean of the window, or `nil` when nothing has been measured.
    public var average: Double? { values.isEmpty ? nil : sum / Double(values.count) }

    /// Percentile of the window, or `nil` below `minimumSamples`.
    public func percentile(_ p: Double, minimumSamples: Int) -> Double? {
        guard values.count >= max(minimumSamples, 1) else { return nil }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(Double(sorted.count) * p))
        return sorted[index]
    }

    public mutating func reset() {
        values.removeAll(keepingCapacity: true)
        next = 0
        sum = 0
    }
}

/// Collects honest per-frame timings for the telemetry readout.
public final class FrameMeter: @unchecked Sendable {
    /// Averaging window for CPU, GPU and output FPS, **in frames**.
    ///
    /// 60 frames is one second at a 60 Hz output. Chosen because:
    ///
    ///  - **Readable.** One late frame moves a 60-sample mean by under 2 %, so
    ///    the digits settle instead of flickering, which is the whole reason a
    ///    rolling average is here rather than a raw per-frame number.
    ///  - **Responsive.** An operator who adds a layer or an effect sees the
    ///    cost land within about a second — short enough to attribute it to the
    ///    thing they just did.
    ///  - **Counted in frames, not seconds.** A duration-based window thins out
    ///    to a handful of samples on a 24 or 30 Hz output and starts flickering
    ///    again exactly where frame budget is tightest. A frame count keeps the
    ///    statistical weight constant and simply spans more wall time (2 s at
    ///    30 Hz), which is still inside the useful range.
    public static let window = 60

    /// Separate, longer window for frame-interval percentiles. A p99 is a
    /// 1-in-100 claim, so it needs at least that many samples to mean anything;
    /// 240 frames (4 s at 60 Hz) gives it a couple of real chances to land.
    public static let percentileWindow = 240

    /// Below this many samples, `frameIntervalP99` reports `nil` rather than
    /// the worst of a short run dressed up as a percentile.
    public static let percentileFloor = 100

    // MARK: Render-thread-only state
    //
    // Touched exclusively from `PhotonEngine.render`. No lock, by construction
    // rather than by convention — nothing else in this file writes to it.

    private var cpu = FrameRing(capacity: FrameMeter.window)
    private var intervals = FrameRing(capacity: FrameMeter.percentileWindow)
    private var frameStart: UInt64 = 0
    private var lastFrameStart: UInt64 = 0
    private var published = FrameSample()

    // MARK: Cross-thread state
    //
    // Written by GPU completion and drawable presentation handlers, which run
    // off the frame path. Read by the render thread with `withLockIfAvailable`
    // so presentation can never be blocked by a handler that happens to be
    // mid-append.

    private struct Shared {
        var gpu = FrameRing(capacity: FrameMeter.window)
        var presentedIntervals = FrameRing(capacity: FrameMeter.window)
        var lastPresentedTime: CFTimeInterval = 0
        /// Frames the engine rendered that never reached the display.
        ///
        /// Measured 2026-10-13 on an M4 Max at 120 Hz: the engine renders every
        /// display-link tick, and **almost exactly half** the drawables come
        /// back with `presentedTime == 0`. Those frames were composited, cost
        /// GPU time, and were then discarded by the window server. That is a
        /// real and useful signal, and it is *observable here*, so it is
        /// counted rather than guessed at.
        ///
        /// It is deliberately NOT called a dropped-frame count. A drop is us
        /// missing a deadline; this is a present that never happened, which may
        /// be perfectly normal when the render rate exceeds the refresh rate.
        /// Conflating the two hides which half of the pipeline is at fault —
        /// the same distinction `EngineTelemetry.sourceRepeats` draws.
        var unpresentedFrames = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())

    public init() {}

    // MARK: - Render thread

    /// Marks the start of the engine's frame build.
    ///
    /// Uses `CLOCK_UPTIME_RAW` — monotonic, unaffected by NTP steps or a user
    /// changing the clock, and not advanced while the machine is asleep. A
    /// wall clock here would record a multi-hour "frame" across a lid close.
    /// Two equal readings mean the span was shorter than the clock's
    /// resolution (~42 ns on Apple Silicon's 24 MHz timebase) — a real
    /// measurement of a very fast span, so it is recorded as zero. Only a
    /// *backwards* reading is rejected, because that is not a span at all.
    public func beginFrame() {
        lastFrameStart = frameStart
        frameStart = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if lastFrameStart > 0, frameStart >= lastFrameStart {
            intervals.append(Double(frameStart - lastFrameStart) / 1_000_000)
        }
    }

    /// Marks the end of the frame build — call after the command buffer is
    /// committed, which is the last CPU work the engine does for this frame.
    public func endFrame() {
        guard frameStart > 0 else { return }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        // As in `beginFrame`: equal is "below clock resolution", backwards is
        // not a measurement.
        guard now >= frameStart else { return }
        cpu.append(Double(now - frameStart) / 1_000_000)
    }

    /// The current measurements.
    ///
    /// Never blocks: if a completion handler holds the lock, the GPU and FPS
    /// figures from the previous call are reused for one more tick. Stale by at
    /// most a sample, never wrong, and never a wait on the render thread.
    public func sample() -> FrameSample {
        var result = FrameSample(
            cpuMilliseconds: cpu.average,
            gpuMilliseconds: published.gpuMilliseconds,
            outputFPS: published.outputFPS,
            frameIntervalP50: intervals.percentile(0.50, minimumSamples: 2),
            frameIntervalP99: intervals.percentile(0.99, minimumSamples: Self.percentileFloor),
            unpresentedFrames: published.unpresentedFrames)

        // Everything behind the lock is read in this one attempt. Reading any
        // of it separately would mean a second lock acquisition on the frame
        // path, and the whole point of `withLockIfAvailable` is that there is
        // exactly one place the render thread could ever contend.
        let fresh = shared.withLockIfAvailable { state -> (Double?, Double?, Int) in
            // An interval only exists once two consecutive frames have both
            // reported a presentation time, so an empty ring means "not yet
            // measurable" — never 0 fps.
            var fps: Double?
            if let mean = state.presentedIntervals.average, mean > 0 { fps = 1.0 / mean }
            return (state.gpu.average.map { $0 * 1000 }, fps, state.unpresentedFrames)
        }
        if let fresh {
            result.gpuMilliseconds = fresh.0
            result.outputFPS = fresh.1
            result.unpresentedFrames = fresh.2
        }
        published = result
        return result
    }

    // MARK: - Off the frame path

    /// Records this buffer's GPU time once it completes.
    ///
    /// `gpuStartTime`/`gpuEndTime` are only populated once the buffer has
    /// finished, so they are read **inside** the completion handler. Reading
    /// them at commit time returns zero and would quietly report a GPU that
    /// costs nothing.
    public func observe(_ buffer: MTLCommandBuffer) {
        buffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            let elapsed = completed.gpuEndTime - completed.gpuStartTime
            // A buffer that did no GPU work, or one Metal declined to time,
            // reports a non-positive span. Counting it as 0 ms would drag the
            // mean toward a figure the GPU never achieved.
            guard elapsed > 0, elapsed.isFinite else { return }
            self.shared.withLock { $0.gpu.append(elapsed) }
        }
    }

    /// Records when this drawable actually reached the display.
    ///
    /// This is the only honest source for output FPS. Counting `render` calls
    /// measures how often *we* were asked to draw; counting presentations
    /// measures what the operator is looking at. The two diverge badly and
    /// routinely — on the dev M4 Max the engine renders at 120 Hz into a
    /// 60 Hz present, so a render-call counter would report double the truth
    /// and look entirely plausible doing it.
    ///
    /// Must be called before `present(_:)`; a handler added afterwards is
    /// never invoked.
    public func observePresentation(of drawable: MTLDrawable) {
        drawable.addPresentedHandler { [weak self] presented in
            guard let self else { return }
            let time = presented.presentedTime
            self.shared.withLock { state in
                // `presentedTime` is 0 when the drawable was never actually
                // presented. Count it, but do **not** treat it as a hole in
                // the timeline: the two frames either side of it really were
                // presented when they say they were, and the interval between
                // them is exactly the rate the display is running at.
                //
                // An earlier version cut the window on every zero. With half
                // the drawables unpresented that meant two good samples never
                // landed in a row, so the readout stayed blank forever — a
                // measurement thrown away by a guard meant to protect it.
                guard time > 0 else {
                    state.unpresentedFrames += 1
                    return
                }
                defer { state.lastPresentedTime = time }
                guard state.lastPresentedTime > 0 else { return }
                let delta = time - state.lastPresentedTime
                // Presentation handlers are not ordered. An out-of-order or
                // duplicate timestamp is not a measurement.
                guard delta > 0 else { return }
                state.presentedIntervals.append(delta)
            }
        }
    }

    /// Frames rendered that the display never showed. See ``Shared``.
    ///
    /// Observed directly from `presentedTime == 0`, so this is a count of a
    /// condition this code can actually see — not an inferred drop count.
    public var unpresentedFrames: Int { shared.withLock { $0.unpresentedFrames } }

    /// Drops every measurement. For a resolution or output change, where the
    /// old samples describe a pipeline that no longer exists.
    public func reset() {
        cpu.reset()
        intervals.reset()
        frameStart = 0
        lastFrameStart = 0
        published = FrameSample()
        shared.withLock { state in
            state.gpu.reset()
            state.presentedIntervals.reset()
            state.lastPresentedTime = 0
            state.unpresentedFrames = 0
        }
    }
}
