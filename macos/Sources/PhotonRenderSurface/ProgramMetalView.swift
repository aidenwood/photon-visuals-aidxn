// Engine-owned Metal surface hosted by PhotonUI's preview panels.
//
// PhotonUI defines the contract (`ProgramSurfaceFactory`) and owns the chrome;
// this provides what renders inside it. PhotonUI never imports Metal.
//
// The view is a thin presentation adapter: it owns a display link and a
// drawable, and nothing else. All composition state lives in `PhotonEngine`,
// so a preview panel appearing, resizing or closing cannot affect program
// output — which is the whole reason the engine is authoritative.

import AppKit
import Metal
import QuartzCore
import PhotonRender
import PhotonUI
import simd

/// Which composition this surface shows.
public enum SurfaceRole: Sendable {
    /// The full composited program output.
    case master
    /// A single clip, pre-composite.
    case clip
}

/// An `NSView` that renders a Photon composition with its own display link.
public final class ProgramMetalView: NSView {
    private let device: MTLDevice
    private let engine: PhotonEngine
    private let role: SurfaceRole
    private var link: CAMetalDisplayLink?
    private var applied: SurfacePlan?
    private var publishing: Task<Void, Never>?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Live telemetry for a stats panel.
    public var telemetry: EngineTelemetry { engine.telemetry }

    /// How often measured timings are handed to the readout. Matches the
    /// engine's own republish interval — polling faster would re-read numbers
    /// it has not recalculated.
    private static let publishInterval = Duration.milliseconds(250)

    public static func make(role: SurfaceRole) -> ProgramMetalView? {
        guard let d = MTLCreateSystemDefaultDevice(),
              let e = PhotonEngine(device: d) else { return nil }
        return ProgramMetalView(device: d, engine: e, role: role)
    }

    private init(device d: MTLDevice, engine e: PhotonEngine, role r: SurfaceRole) {
        self.device = d
        self.engine = e
        self.role = r
        super.init(frame: .zero)

        // Must come from makeBackingLayer(); assigning `layer` after
        // `wantsLayer = true` is not honoured by AppKit.
        wantsLayer = true
        // Present immediately with an empty stack. The composition arrives from
        // the workspace via `apply(_:)`; nothing is loaded speculatively here.
        startLink()
    }

    required init?(coder: NSCoder) { nil }

    public override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        ml.device = device
        ml.pixelFormat = .bgra8Unorm_srgb
        ml.framebufferOnly = true
        ml.isOpaque = true
        return ml
    }

    // No `deinit` teardown: Swift 6 forbids touching a non-Sendable
    // CAMetalDisplayLink from a nonisolated deinit, so teardown is explicit and
    // driven by window attachment instead.

    private func startLink() {
        guard link == nil else { return }
        let l = CAMetalDisplayLink(metalLayer: metalLayer)
        l.delegate = self
        l.preferredFrameLatency = 2
        l.add(to: .main, forMode: .common)
        link = l
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            // Detached — stop the link outright rather than pausing, so a closed
            // preview panel holds no display-link registration at all.
            link?.invalidate()
            link = nil
            // And blank the readout. Numbers from a renderer that has stopped
            // are not measurements of anything.
            stopPublishing()
        } else {
            startLink()
            startPublishing()
        }
        updateDrawableSize()
    }

    // MARK: - Telemetry publishing

    /// Starts handing the engine's measured timings to the corner readout.
    ///
    /// Only the **master** surface publishes. A clip preview renders a single
    /// pre-composite source on its own engine, so its frame cost is not the
    /// program's — showing it under a label that says "Output" would be a
    /// measurement of the wrong thing, which is the same failure as inventing
    /// one. The bus enforces a single owner, so a second master surface is
    /// refused rather than interleaved.
    ///
    /// Reads `engine.telemetry` from the main actor. That is safe *because*
    /// the display link is added to the main run loop, so the render callback
    /// that writes it and this task that reads it are the same thread — the
    /// struct can never be torn. If the link is ever moved to its own thread,
    /// this read needs revisiting; nothing else here does.
    ///
    /// This is deliberately a poll off the frame path rather than a push from
    /// `render`: the render thread must never take the bus's lock.
    private func startPublishing() {
        guard role == .master, publishing == nil,
              LiveTelemetryBus.shared.claim(self) else { return }
        publishing = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: ProgramMetalView.publishInterval) } catch { return }
                guard let self, self.window != nil else { return }
                let t = self.engine.telemetry
                // Passed straight through. A metric the engine could not
                // measure stays nil all the way to the readout's "—".
                LiveTelemetryBus.shared.publish(
                    TelemetrySnapshot(cpuMilliseconds: t.cpuTime,
                                      gpuMilliseconds: t.gpuTime,
                                      outputFPS: t.outputFPS),
                    from: self)
            }
        }
    }

    private func stopPublishing() {
        publishing?.cancel()
        publishing = nil
        LiveTelemetryBus.shared.release(self)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        let size = CGSize(width: max(bounds.width, 1) * scale,
                          height: max(bounds.height, 1) * scale)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
    }

    // MARK: - Composition

    /// Applies the workspace's composition to this surface.
    ///
    /// This is the whole point of the view: what a grid trigger launches is
    /// what this renders. It previously loaded whatever media sat in the repo,
    /// ignoring the workspace entirely, so selection could never reach output.
    ///
    /// An unchanged plan is ignored. `setLayers` only keeps a source whose URL
    /// is identical, so re-applying on every unrelated SwiftUI update would
    /// restart playback on each one.
    func apply(_ plan: SurfacePlan) {
        guard applied != plan else { return }
        applied = plan
        engine.masterOpacity = Float(plan.masterOpacity)
        engine.blackout = plan.blackout
        engine.bpm = plan.bpm
        // Set before `setLayers` so a source opened by this same call inherits
        // the transport rather than playing for one apply and then stopping.
        engine.isPlaying = plan.playing
        // Index is the stable layer identity here: the plan always carries the
        // full stack in draw order, so a bypassed or cleared layer keeps its
        // slot and its neighbours keep their already-open sources.
        engine.setLayers(plan.layers.enumerated().map { index, layer in
            LayerState(
                id: index,
                name: layer.name,
                // Resolume semantics: the clip's fader and the layer's master
                // are independent and multiply. The engine holds one opacity
                // per layer, so the product is formed here — the only place
                // that knows both values — rather than either control
                // overwriting the other's state upstream.
                opacity: Float(layer.opacity * layer.clipOpacity),
                // `BlendMode(rawValue:)` is the whole translation. There is no
                // name table to fall out of step with the enum; an id the
                // engine does not define falls back to `.over`, which is the
                // compositor's own default rather than a different-looking mode.
                blend: BlendMode(rawValue: layer.blendModeID) ?? .over,
                bypassed: layer.bypassed,
                soloed: layer.soloed,
                clipURL: layer.url,
                effects: Self.chain(layer.effects))
        })
    }

    /// An unrecognised kind is dropped, not substituted. A chain that silently
    /// ran the wrong effect would be worse than one that ran one fewer.
    private static func chain(_ effects: [SurfacePlan.Effect]) -> [Effect] {
        effects.compactMap { effect in
            EffectKind(rawValue: effect.kind).map {
                Effect(kind: $0, amount: Float(effect.amount),
                       param: Float(effect.param), enabled: effect.enabled)
            }
        }
    }

    // MARK: - Commands (for the UI to drive later)

    public func setOpacity(layer id: Int, _ v: Float) { engine.setOpacity(layer: id, v) }
    public func setBlend(layer id: Int, _ m: BlendMode) { engine.setBlend(layer: id, m) }
    public func setBlackout(_ on: Bool) { engine.blackout = on }
    /// Presentation bridge for the editor's current preview slice. Engine owns warping.
    public func setMappingCorners(_ normalized: [SIMD2<Double>]) {
        guard normalized.count == 4, normalized.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              !engine.topology.screens.isEmpty, !engine.topology.screens[0].slices.isEmpty else { return }
        let corners = normalized.map { SIMD2<Float>(Float($0.x * 2 - 1), Float(1 - $0.y * 2)) }
        guard engine.topology.screens[0].slices[0].corners != corners else { return }
        engine.topology.screens[0].slices[0].corners = corners
    }
    public var layers: [LayerState] { engine.layers }
}

extension ProgramMetalView: @preconcurrency CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(_ link: CAMetalDisplayLink,
                                 needsUpdate update: CAMetalDisplayLink.Update) {
        engine.render(drawable: update.drawable)
    }
}
