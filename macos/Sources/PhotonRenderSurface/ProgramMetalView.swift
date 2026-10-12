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
    private var mediaLoad: Task<Void, Never>?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Live telemetry for a stats panel.
    public var telemetry: EngineTelemetry { engine.telemetry }

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
        // Present immediately. Desktop/iCloud directory access can block in
        // open(2); it must never run during SwiftUI's makeNSView/layout pass.
        loadDefaultComposition(urls: [])
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
            mediaLoad?.cancel()
            mediaLoad = nil
        } else {
            startLink()
            loadDevelopmentMedia()
        }
        updateDrawableSize()
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

    // MARK: - Default composition

    /// Media shipped alongside the repo for development. Absent in a packaged
    /// build, in which case the engine falls back to procedural layers — the
    /// preview must always show *something* rather than going black.
    nonisolated private static func mediaURLs() -> [URL] {
        let staged = Bundle.main.resourceURL?.appendingPathComponent("DevelopmentMedia")
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // .../Sources/PhotonRenderSurface
            .deletingLastPathComponent()   // .../Sources
            .deletingLastPathComponent()   // .../macos
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("media-cache")
        let base = staged ?? checkout
        guard let names = try? FileManager.default
            .contentsOfDirectory(atPath: base.path) else { return [] }
        return names.filter { $0.hasSuffix(".mp4") }
            .sorted()
            .map { base.appendingPathComponent($0) }
    }

    private func loadDevelopmentMedia() {
        guard mediaLoad == nil else { return }
        mediaLoad = Task { [weak self] in
            let urls = await Self.developmentMedia.value
            guard !Task.isCancelled, let self, self.window != nil, !urls.isEmpty else { return }
            self.loadDefaultComposition(urls: urls)
        }
    }

    // One bounded development scan shared by both monitors, including remounts.
    // Named explicitly rather than via `Self`: a static stored-property
    // initializer cannot reference the covariant `Self` type.
    nonisolated private static let developmentMedia =
        Task.detached(priority: .utility) { ProgramMetalView.mediaURLs() }

    private func loadDefaultComposition(urls: [URL]) {
        // Master composites a stack; a clip preview is pre-composite by
        // definition, so it shows a single source.
        let wanted = role == .master ? min(urls.count, 3) : min(urls.count, 1)
        let blends: [BlendMode] = [.over, .screen, .add, .lighten]

        let states = (0..<max(wanted, 1)).map { i in
            LayerState(
                id: i,
                name: i < urls.count
                    ? urls[i].deletingPathExtension().lastPathComponent
                    : "Layer \(i + 1)",
                opacity: i == 0 ? 1.0 : 0.8,
                blend: blends[i % blends.count],
                clipURL: i < wanted ? urls[i] : nil)
        }
        engine.setLayers(states)
    }

    // MARK: - Commands (for the UI to drive later)

    public func setOpacity(layer id: Int, _ v: Float) { engine.setOpacity(layer: id, v) }
    public func setBlend(layer id: Int, _ m: BlendMode) { engine.setBlend(layer: id, m) }
    public func setBlackout(_ on: Bool) { engine.blackout = on }
    public var layers: [LayerState] { engine.layers }
}

extension ProgramMetalView: @preconcurrency CAMetalDisplayLinkDelegate {
    public func metalDisplayLink(_ link: CAMetalDisplayLink,
                                 needsUpdate update: CAMetalDisplayLink.Update) {
        engine.render(drawable: update.drawable)
    }
}
