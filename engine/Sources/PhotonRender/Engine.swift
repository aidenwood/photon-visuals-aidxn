// The engine facade — what a UI drives.
//
// Owns sources, the layer stack, transport and the render loop. Everything the
// front end needs is a command here; the front end never touches Metal, never
// holds a texture, and never learns what a codec is.
//
// Deliberate design points:
//  - **The engine is authoritative.** A UI panel closing, reloading or crashing
//    must never change what is on the program output.
//  - **Commands are idempotent and cheap.** They mutate state; they never block
//    on the GPU and never do I/O on the caller's thread.
//  - **A missing or late source holds its last valid frame.** Blackout is an
//    explicit operator command, never an accident of decode timing.

import Foundation
import Metal
import QuartzCore
import simd

/// One layer in the composition, as the UI sees it.
public struct LayerState: Sendable {
    /// Stable identity, so a reorder or rename does not break bindings.
    public let id: Int
    public var name: String
    /// 0...1
    public var opacity: Float
    public var blend: BlendMode
    /// Excluded from the composite entirely.
    public var bypassed: Bool
    /// When any layer is soloed, non-soloed layers are excluded.
    public var soloed: Bool
    /// Media currently assigned, if any.
    public var clipURL: URL?
    /// Effects applied to this layer before it joins the composite.
    ///
    /// A layer with effects **breaks out of the folded path**, renders to its
    /// own target, runs its chain, then rejoins the stack as an ordinary
    /// source texture. A layer with none costs nothing extra.
    public var effects: [Effect]

    public init(id: Int, name: String, opacity: Float = 1, blend: BlendMode = .over,
                bypassed: Bool = false, soloed: Bool = false, clipURL: URL? = nil,
                effects: [Effect] = []) {
        self.id = id
        self.name = name
        self.opacity = opacity
        self.blend = blend
        self.bypassed = bypassed
        self.soloed = soloed
        self.clipURL = clipURL
        self.effects = effects
    }
}

/// Live numbers for a telemetry panel.
///
/// The four timing figures are **optional on purpose**. Each has a real state
/// in which it is unknown — no frame has completed, no buffer has come back
/// from the GPU, nothing has been presented to a display — and in that state
/// it reads as `nil`, which the UI renders as "—". None of them is ever
/// substituted with a target rate, an estimate, or a zero. A readout that
/// invents a number is worse than a blank one, because a blank one is the only
/// version that sends the operator looking for the cause.
///
/// Measurement, windows and threading live in ``FrameMeter``.
public struct EngineTelemetry: Sendable {
    /// Frames per second the display actually presented. Derived from
    /// `MTLDrawable` presentation timestamps, **not** from the render-call
    /// rate and never from the target rate — the two only diverge when
    /// something is wrong, which is exactly when the number is being read.
    public var outputFPS: Double?
    /// Median wall interval between frames, ms. Cadence, not cost.
    public var frameTimeP50: Double?
    /// 99th-percentile frame interval, ms. `nil` until there are enough
    /// samples for a 1-in-100 figure to mean anything.
    public var frameTimeP99: Double?
    /// Mean GPU milliseconds per frame, from completed command buffers.
    public var gpuTime: Double?
    /// Mean CPU milliseconds the engine spent building and submitting a frame.
    /// Separate from ``frameTimeP50``: a frame can be cheap on the CPU and
    /// still arrive late.
    public var cpuTime: Double?
    /// Frames composited that the display never showed, since startup.
    ///
    /// Observed from `presentedTime == 0`, so it counts a condition this code
    /// can actually see. **Not a dropped-frame count** — rendering faster than
    /// the refresh rate produces these by design, which is the common case on
    /// a 120 Hz panel driving a 60 Hz present.
    public var unpresentedFrames: Int = 0
    public var activeLayers: Int = 0
    /// Frames a source could not supply in time. **Distinct from a dropped
    /// frame**: a repeat means the SOURCE was late, a drop means WE missed a
    /// deadline. Conflating them hides which half of the pipeline is at fault.
    public var sourceRepeats: Int = 0
    /// True when the stack contains a blend mode that cannot be expressed by
    /// fixed-function blending, so the folded path is required.
    public var requiresDestinationRead: Bool = false
    /// Layers that broke out of the folded path to run effects.
    public var effectedLayers: Int = 0
    /// Total effect passes this frame.
    public var effectPasses: Int = 0
}

/// Owns the composition and drives rendering.
public final class PhotonEngine: @unchecked Sendable {
    public static let maxLayers = Compositor.maxTextures

    private let device: MTLDevice
    private let compositor: Compositor
    private let outputStage: OutputStage?
    private let effects: EffectChain?

    /// Audio analysis, for audio-reactive modulation. Always present; live
    /// capture is opt-in via `startAudioInput()`.
    public let audio = AudioAnalyser()
    private lazy var audioInput = AudioInput(analyser: audio)
    /// MIDI control surfaces. Opt-in via `startMidi()`.
    public let midi = MidiInput()

    /// The clip grid. Triggering is quantised against `beat` below.
    public var deck = Deck(layers: 4, columns: 8)

    /// Cue list / autopilot. Advancing fires through the deck, so an
    /// auto-advance is quantised exactly like a manual press.
    public var cues = CueList()

    /// Continuous musical position.
    ///
    /// Comes from `photon-core`'s clock when the shell supplies it — see
    /// ``adoptMusicalTime(beat:bpm:)``. The local accumulator below is the
    /// fallback for when nothing has, and exists so the deck can be driven and
    /// tested without a core handle.
    ///
    /// It is **not** a second implementation of the clock. `clock.rs` carries
    /// the parts that matter — separable tempo and phase sources, slewed
    /// correction rather than jumps, tap tempo with outlier rejection — and
    /// this must never grow any of them. If it needs a feature the core has,
    /// the answer is to call the core.
    public private(set) var beat: Double = 0

    /// Where musical time comes from.
    public enum TimeSource: Sendable, Equatable {
        /// The local accumulator. No core handle has spoken yet.
        case local
        /// `photon-core`'s clock, pushed in by the shell each frame.
        case core
    }

    /// Which clock is driving. Read-only; set by calling
    /// ``adoptMusicalTime(beat:bpm:)``.
    public private(set) var timeSource: TimeSource = .local

    /// Adopts musical time from the core's clock for this frame.
    ///
    /// Called once per frame by the shell, after `photon_tick`. From the first
    /// call onwards the local accumulator stops: running both would mean two
    /// clocks disagreeing by a fraction of a beat, which shows up as a launch
    /// landing a frame early and is almost impossible to diagnose from the
    /// symptom.
    ///
    /// A **backwards** jump is honoured rather than clamped — a resync is
    /// supposed to move time. The cost is that a launch already quantised past
    /// the new position waits for the grid to come round again, which is the
    /// musically correct behaviour anyway.
    public func adoptMusicalTime(beat: Double, bpm: Double) {
        guard beat.isFinite, bpm.isFinite, bpm > 0 else { return }
        timeSource = .core
        self.beat = beat
        self.bpm = bpm
    }

    private var layerStates: [LayerState] = []
    private var sources: [Int: FrameSource] = [:]      // layer id -> source
    private var heldTextures: [Int: MTLTexture] = [:]  // layer id -> last good frame

    private var uniforms: [LayerUniform] = []
    private var boundTextures: [MTLTexture?] = []

    private var t: Float = 0
    private var lastFrame = CACurrentMediaTime()
    private var effectedLayersThisFrame = 0
    private var effectPassesThisFrame = 0
    private var lastReport = CACurrentMediaTime()

    /// Frame timing. Owns every number in ``telemetry`` that is a duration or
    /// a rate; nothing else in the engine measures time for display.
    public let meter = FrameMeter()

    /// Transport run state for every clip in the composition.
    ///
    /// A pause **holds the frame** — sources stop advancing, the compositor
    /// keeps presenting what they last supplied, and the display link keeps
    /// running. It is not a blackout and it is not a stall: an operator who
    /// pauses expects the image to stay on the screen, and the output must
    /// keep presenting at a steady cadence either way.
    ///
    /// Musical time is deliberately unaffected. `beat` keeps advancing so the
    /// grid, cue list and any synced lighting stay in phase across a pause;
    /// stopping the clock instead would make the first launch after a resume
    /// land wherever the pause happened to end.
    public var isPlaying: Bool = true {
        didSet {
            guard isPlaying != oldValue else { return }
            for (_, src) in sources { isPlaying ? src.play() : src.pause() }
        }
    }

    /// Master opacity, applied after the composite.
    public var masterOpacity: Float = 1
    /// Explicit operator blackout. Never set implicitly by decode failure.
    public var blackout: Bool = false
    /// Animate layer transforms with a sine sweep — a demo flourish only.
    ///
    /// **Defaults off.** It used to default on, which meant every consumer that
    /// did not know to switch it off — including the app's own preview — showed
    /// layers drifting and scaling on their own, looking like a bug in playback.
    /// A demo behaviour must be opted into by the demo, not opted out of by
    /// everything else.
    public var animateTransforms: Bool = false

    /// When set, the composite is replaced by a full-screen test pattern.
    ///
    /// Rigging is a different mode from performing: you are aligning the
    /// projector, not watching content, so the pattern **replaces** the stack
    /// rather than blending over it.
    public var patternKind: LayerKind?

    public private(set) var telemetry = EngineTelemetry()

    /// The venue's output mapping. Travels separately from the composition, so
    /// the same show can be re-hung somewhere else without re-cutting it.
    ///
    /// Setting this replaces `slices`. Defaults to a single full-canvas screen
    /// so an operator who has mapped nothing still gets output.
    public var topology: OutputTopology = .singleScreen() {
        didSet {
            let s = topology.activeSlices()
            // Never leave the output with nothing to draw: an empty or
            // all-disabled mapping falls back rather than going black, because
            // blackout must stay an explicit operator action.
            slices = s.isEmpty ? [OutputStage.identitySlice()] : s
        }
    }

    /// Output slices — one per projector. Derived from `topology`.
    public var slices: [OutputSlice] = [OutputStage.identitySlice()]

    /// Mapping failures, surfaced rather than silently projecting nothing.
    public var sliceFailures: [Int: String] { outputStage?.failedSlices ?? [:] }

    public init?(device: MTLDevice) {
        guard let c = Compositor(device: device) else { return nil }
        self.device = device
        self.compositor = c
        self.outputStage = OutputStage(device: device)
        self.effects = EffectChain(device: device)
        // The compositor's own unwarped fallback path makes its own command
        // buffer, so it needs the same meter rather than a second one.
        c.meter = meter
    }

    // MARK: - Commands

    /// Replaces the whole layer stack. Sources for layers that kept the same
    /// clip are **retained**, so re-ordering or renaming does not restart video.
    public func setLayers(_ states: [LayerState]) {
        let capped = Array(states.prefix(Self.maxLayers))
        let keep = Set(capped.compactMap { st -> Int? in
            guard let url = st.clipURL, let existing = sources[st.id] else { return nil }
            return existing.url == url ? st.id : nil
        })
        for (id, _) in sources where !keep.contains(id) {
            sources[id] = nil
            heldTextures[id] = nil
        }
        for st in capped where st.clipURL != nil && sources[st.id] == nil {
            if let url = st.clipURL, let src = makeFrameSource(url: url, device: device) {
                src.bpm = bpm
                // A source opened while the transport is paused must not start
                // running on its own: launching a clip into a paused
                // composition would make pause look broken on exactly the one
                // layer that just changed.
                if !isPlaying { src.pause() }
                sources[st.id] = src
            }
        }
        layerStates = capped
    }

    /// Assigns media to a layer. Passing `nil` clears it without disturbing others.
    public func setClip(layer id: Int, url: URL?) {
        guard let idx = layerStates.firstIndex(where: { $0.id == id }) else { return }
        layerStates[idx].clipURL = url
        heldTextures[id] = nil
        guard let url else { sources[id] = nil; return }
        let src = makeFrameSource(url: url, device: device)
        src?.bpm = bpm
        if !isPlaying { src?.pause() }
        sources[id] = src
    }

    public func setOpacity(layer id: Int, _ value: Float) {
        guard let idx = layerStates.firstIndex(where: { $0.id == id }) else { return }
        layerStates[idx].opacity = max(0, min(1, value))
    }

    public func setBlend(layer id: Int, _ mode: BlendMode) {
        guard let idx = layerStates.firstIndex(where: { $0.id == id }) else { return }
        layerStates[idx].blend = mode
    }

    /// Replaces a layer's effect chain.
    public func setEffects(layer id: Int, _ chain: [Effect]) {
        guard let idx = layerStates.firstIndex(where: { $0.id == id }) else { return }
        layerStates[idx].effects = chain
    }

    /// Sets how a layer's clip plays — timeline, BPM-synced, or parameter-driven.
    public func setTransport(layer id: Int, _ transport: ClipTransport) {
        sources[id]?.transport = transport
    }

    /// Tempo, propagated to every BPM-synced clip.
    ///
    /// Held here rather than per source so a tempo change lands on all synced
    /// clips in the same frame — staggering it would visibly break the lock.
    public var bpm: Double = 120 {
        didSet { for (_, src) in sources { src.bpm = bpm } }
    }

    public func setBypassed(layer id: Int, _ bypassed: Bool) {
        guard let idx = layerStates.firstIndex(where: { $0.id == id }) else { return }
        layerStates[idx].bypassed = bypassed
    }

    public var layers: [LayerState] { layerStates }

    /// Starts live audio capture. **Fails soft** — a denied microphone
    /// permission or absent device costs audio reactivity, never the show.
    @discardableResult
    public func startAudioInput() -> Bool { audioInput.start() }
    public func stopAudioInput() { audioInput.stop() }
    /// Operator-facing audio status.
    public var audioStatus: String { audioInput.status }

    /// Opens MIDI sources. Fails soft for the same reason.
    @discardableResult
    public func startMidi() -> Bool { midi.start() }
    public func stopMidi() { midi.stop() }
    /// Operator-facing MIDI status.
    public var midiStatus: String { midi.status }

    /// Consumes pending MIDI and applies anything the engine owns.
    ///
    /// Called once per frame. Tempo from MIDI clock is adopted automatically so
    /// BPM-synced clips lock to an external source without configuration.
    /// Loads the deck's current state as the layer stack.
    ///
    /// Call after populating cells; subsequent triggers update incrementally.
    public func syncFromDeck() {
        setLayers(deck.layerStates())
    }

    /// Fires the next cue. Behaves identically in manual and autopilot, so an
    /// operator can always take control without the list losing its place.
    @discardableResult
    public func go() -> Int? {
        guard let column = cues.go(atBeat: beat) else { return nil }
        deck.triggerColumn(column, atBeat: beat)
        return column
    }

    /// Fires a grid column, quantised.
    public func triggerColumn(_ column: Int) {
        deck.triggerColumn(column, atBeat: beat)
    }

    /// Fires one cell, quantised.
    public func triggerCell(layer: Int, column: Int) {
        deck.trigger(layer: layer, column: column, atBeat: beat)
    }

    public func pumpMidi() -> [MidiMessage] {
        let messages = midi.drain()
        if let external = midi.bpm, abs(external - bpm) > 0.01 {
            bpm = external
        }
        return messages
    }

    /// Layers that actually render: solo wins over bypass, matching every tool
    /// in this category — an operator soloing a layer expects exactly that layer.
    private var activeLayers: [LayerState] {
        let soloed = layerStates.filter { $0.soloed && !$0.bypassed }
        return soloed.isEmpty ? layerStates.filter { !$0.bypassed } : soloed
    }

    // MARK: - Render

    /// Renders one frame. Called from the presentation adapter's display link.
    public func render(drawable: CAMetalDrawable) {
        // Opens the CPU measurement for this frame. Closed after commit, which
        // is the last CPU work the engine does for it.
        meter.beginFrame()
        // Registered before `present` — a handler added afterwards is never
        // called. This is the only source of the output FPS figure.
        meter.observePresentation(of: drawable)

        let now = CACurrentMediaTime()
        let dt = now - lastFrame
        lastFrame = now
        t += Float(min(dt, 1.0 / 30.0))

        // Drain MIDI once per frame; external clock is adopted here so
        // BPM-synced clips lock without configuration.
        _ = pumpMidi()

        // Advance musical time, then fire anything whose quantised boundary
        // has passed. Reload only the layers that actually changed.
        // Only when nothing authoritative is driving. Two clocks disagreeing by
        // a fraction of a beat is a launch landing a frame early, with nothing
        // in the symptom to point at the cause.
        if timeSource == .local {
            beat += dt * (bpm / 60.0)
        }

        // Autopilot advances through the deck, not around it, so an automatic
        // step lands on the beat exactly as a manual GO would.
        if let column = cues.tick(atBeat: beat) {
            deck.triggerColumn(column, atBeat: beat)
        }

        let changed = deck.advance(toBeat: beat)
        if !changed.isEmpty {
            for layer in changed {
                let states = deck.layerStates()
                guard layer < states.count else { continue }
                setClip(layer: layer, url: states[layer].clipURL)
                setEffects(layer: layer, states[layer].effects)
            }
        }

        var active = activeLayers
        if let pattern = patternKind {
            active = [LayerState(id: -1, name: pattern.name, opacity: 1, blend: .over)]
        }
        uniforms.removeAll(keepingCapacity: true)
        boundTextures.removeAll(keepingCapacity: true)

        var repeats = 0
        var needsDest = false

        for (slot, st) in active.enumerated() {
            var texSlot: Int32 = -1
            // Default to "the whole texture, straight RGB" — the block path
            // overrides both, and getting either wrong is visible rather than
            // subtle (garbage down one edge, or a dark picture).
            var texScale = SIMD2<Float>(1, 1)
            var flags: Int32 = 0

            if let src = sources[st.id] {
                // nil means no new frame — hold the previous one rather than
                // stalling. A late source must never block the render thread.
                if let tex = src.texture(at: now) {
                    heldTextures[st.id] = tex
                }
                repeats += src.repeatedFrames
                if let held = heldTextures[st.id] {
                    boundTextures.append(held)
                    texSlot = Int32(slot)
                    texScale = src.textureScale
                    if src.isPremultiplied { flags |= LayerUniform.flagPremultiplied }
                }
            }

            if texSlot < 0 { boundTextures.append(nil) }
            if st.blend.needsDestination { needsDest = true }

            var offsetScale = SIMD4<Float>(0, 0, 1, 1)
            if animateTransforms {
                let f = Float(slot) * 0.7
                let s = 0.55 + 0.35 * sin(t * 0.4 + f)
                offsetScale = .init(0.18 * sin(t * 0.5 + f),
                                    0.18 * cos(t * 0.37 + f * 1.3), s, s)
            }

            uniforms.append(LayerUniform(
                tint: .init(1, 1, 1, 1),
                offsetScale: patternKind != nil ? .init(0, 0, 1, 1) : offsetScale,
                opacity: blackout ? 0 : st.opacity * masterOpacity,
                blend: st.blend,
                kind: patternKind?.rawValue ?? (texSlot >= 0 ? 3 : Int32(slot % 3)),
                texSlot: patternKind != nil ? -1 : texSlot,
                texScale: texScale,
                flags: flags))
        }

        if uniforms.isEmpty {
            // Nothing to draw. Still present a cleared frame so the display
            // link keeps a steady cadence rather than stuttering.
            uniforms.append(LayerUniform(tint: .init(0, 0, 0, 1),
                                         offsetScale: .init(0, 0, 1, 1),
                                         opacity: 1, blend: .over, kind: 0))
            boundTextures.append(nil)
        }

        // Composite once in linear light, then warp it into every slice.
        if let stage = outputStage, let cb = compositor.makeCommandBuffer() {
            // Hybrid compositor: layers WITH effects break out here, render
            // their chain into a private target, and rejoin the fold below as
            // an ordinary texture. Layers without effects are untouched.
            if let fx = effects {
                var passes = 0, effected = 0
                for (slot, st) in active.enumerated() where !st.effects.isEmpty {
                    guard slot < boundTextures.count,
                          let input = boundTextures[slot] else { continue }
                    // The clock MUST be threaded through here. Both arguments
                    // default to 0, and with the defaults taken every
                    // time-varying effect is frozen in the real engine while
                    // looking perfectly correct in the verifier, which passes
                    // the clock explicitly. Strobe, noise and wave sat dead
                    // still on stage and nothing failed anywhere.
                    let out = fx.apply(st.effects, to: input, in: cb,
                                       time: t, beat: beat)
                    if out !== input {
                        boundTextures[slot] = out
                        effected += 1
                        passes += fx.passesLastFrame
                    }
                }
                effectedLayersThisFrame = effected
                effectPassesThisFrame = passes
            }
            let w = drawable.texture.width, h = drawable.texture.height
            if let work = compositor.composite(into: cb, layers: uniforms, time: t,
                                               width: w, height: h,
                                               textures: boundTextures) {
                let rp = MTLRenderPassDescriptor()
                rp.colorAttachments[0].texture = drawable.texture
                rp.colorAttachments[0].loadAction = .clear
                rp.colorAttachments[0].storeAction = .store
                rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                stage.encode(into: cb, descriptor: rp, source: work, slices: slices)
            }
            meter.observe(cb)
            cb.present(drawable)
            cb.commit()
        } else {
            compositor.render(layers: uniforms, time: t,
                              drawable: drawable, output: drawable.texture,
                              textures: boundTextures)
        }

        meter.endFrame()

        // Republished at a human reading rate, not every frame — the numbers
        // underneath are already averaged, and a 60 Hz text update is unreadable.
        if now - lastReport >= 0.25 {
            updateTelemetry(active: active.count,
                            repeats: repeats, needsDest: needsDest)
            lastReport = now
        }
    }

    private func updateTelemetry(active: Int, repeats: Int, needsDest: Bool) {
        let sample = meter.sample()
        telemetry = EngineTelemetry(
            outputFPS: sample.outputFPS,
            frameTimeP50: sample.frameIntervalP50,
            frameTimeP99: sample.frameIntervalP99,
            gpuTime: sample.gpuMilliseconds,
            cpuTime: sample.cpuMilliseconds,
            unpresentedFrames: sample.unpresentedFrames,
            activeLayers: active,
            sourceRepeats: repeats,
            requiresDestinationRead: needsDest,
            effectedLayers: effectedLayersThisFrame,
            effectPasses: effectPassesThisFrame)
    }
}
