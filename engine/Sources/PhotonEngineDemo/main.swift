// Photon engine demo — everything the engine does, drivable from the keyboard.
//
// Runs the real `PhotonEngine`: media decode, register-folded compositing in
// linear light, per-layer effects, and projection-mapped warp output with soft
// edge and per-slice colour correction.
//
// Keys
//   ↑ ↓   layers                 T   cycle test pattern
//   B     blend mode (top)       K   keystone the output
//   E     cycle effect           S   rig: single / 2-projector / 4-projector
//   C     colour-trim proj 1     M   media on/off
//   R     reset mapping          Space  pause motion      Q  quit

import AppKit
import Metal
import QuartzCore
import PhotonRender
import simd

final class DemoView: NSView {
    private let device: MTLDevice
    private let engine: PhotonEngine
    private var link: CAMetalDisplayLink?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private var layerCount = 3
    private var topBlend: BlendMode = .screen
    private var testPattern: LayerKind?
    private var effectIndex = -1
    private var rig = 0
    private var keystoned = false
    private var trimmed = false
    private var useMedia = true
    private var mediaURLs: [URL] = []
    private var lastReport = CACurrentMediaTime()
    private var statTicks = 0

    var onStats: ((String) -> Void)?

    static func make() -> DemoView? {
        guard let d = MTLCreateSystemDefaultDevice(),
              let e = PhotonEngine(device: d) else { return nil }
        return DemoView(device: d, engine: e)
    }

    private init(device d: MTLDevice, engine e: PhotonEngine) {
        self.device = d
        self.engine = e
        super.init(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        wantsLayer = true
        mediaURLs = Self.findMedia()
        populateDeck()
        rebuild()
        applyRig()
        // The link is started in viewDidMoveToWindow, NOT here: CAMetalDisplayLink
        // needs its layer attached to a visible window before it will fire. Creating
        // it in init silently produces a black window that never draws.
    }

    private func startLink() {
        guard link == nil else { return }
        let l = CAMetalDisplayLink(metalLayer: metalLayer)
        l.delegate = self
        l.preferredFrameLatency = 2
        l.add(to: .main, forMode: .common)
        link = l
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            link?.invalidate()
            link = nil
        } else {
            startLink()
        }
        sizeDrawable()

    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func makeBackingLayer() -> CALayer {
        let ml = CAMetalLayer()
        ml.device = device
        // Linear in; the hardware encodes on write. One convention everywhere.
        ml.pixelFormat = .bgra8Unorm_srgb
        ml.framebufferOnly = true
        ml.isOpaque = true
        return ml
    }

    override func setFrameSize(_ s: NSSize) { super.setFrameSize(s); sizeDrawable() }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties(); sizeDrawable()
    }

    private func sizeDrawable() {
        let scale = window?.backingScaleFactor ?? 2
        let want = CGSize(width: max(bounds.width, 1) * scale,
                          height: max(bounds.height, 1) * scale)
        metalLayer.contentsScale = scale
        if metalLayer.drawableSize != want { metalLayer.drawableSize = want }
    }

    private static func findMedia() -> [URL] {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("media-cache")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        return names.filter { $0.hasSuffix(".mp4") }.sorted()
            .map { base.appendingPathComponent($0) }
    }

    /// Fills the grid with whatever media is available, so number keys fire
    /// real columns rather than empty cells.
    private func populateDeck() {
        guard !mediaURLs.isEmpty else { return }
        var deck = Deck(layers: 3, columns: 8)
        deck.quantise = .bar
        for layer in 0..<3 {
            for column in 0..<8 {
                // Offset per layer so each column is a different combination
                // rather than the same clip three times.
                let idx = (column + layer * 3) % mediaURLs.count
                let url = mediaURLs[idx]
                deck[layer, column] = Cell(
                    clipURL: url,
                    name: url.deletingPathExtension().lastPathComponent)
            }
        }
        engine.deck = deck
    }

    private func rebuild() {
        // Rigging is a different mode from performing: a test pattern replaces
        // the stack rather than blending over it.
        engine.patternKind = testPattern
        guard testPattern == nil else {
            engine.setLayers([LayerState(id: 0, name: "pattern", opacity: 1, blend: .over)])
            return
        }
        let blends: [BlendMode] = [.over, .screen, .add, .lighten, .difference]
        let states = (0..<layerCount).map { i -> LayerState in
            var fx: [Effect] = []
            if i == 0, effectIndex >= 0 {
                fx = [Effect(kind: EffectKind.allCases[effectIndex], amount: 0.6, param: 0.4)]
            }
            let url = (useMedia && i < mediaURLs.count) ? mediaURLs[i] : nil
            return LayerState(
                id: i,
                name: url?.deletingPathExtension().lastPathComponent ?? "Layer \(i + 1)",
                opacity: i == 0 ? 1.0 : 0.85,
                blend: i == layerCount - 1 ? topBlend : blends[i % blends.count],
                clipURL: url,
                effects: fx)
        }
        engine.setLayers(states)
    }

    private func applyRig() {
        var topology: OutputTopology
        switch rig {
        case 1: topology = .splitter(projectors: 2)
        case 2: topology = .splitter(projectors: 4)
        default: topology = .singleScreen()
        }
        if keystoned, !topology.screens.isEmpty, !topology.screens[0].slices.isEmpty {
            // Deliberately asymmetric: an affine (wrong) implementation bends
            // the image along the shared triangle diagonal under exactly this.
            topology.screens[0].slices[0].corners = [
                .init(-0.85, 0.95), .init(0.9, 0.7),
                .init(0.75, -0.9), .init(-0.95, -0.65),
            ]
        }
        if trimmed, !topology.screens.isEmpty, !topology.screens[0].slices.isEmpty {
            topology.screens[0].slices[0].gain = .init(1.0, 0.6, 0.6)
        }
        engine.topology = topology
    }

    fileprivate func draw(_ drawable: CAMetalDrawable) {
        sizeDrawable()
        engine.render(drawable: drawable)

        let now = CACurrentMediaTime()
        guard now - lastReport > 0.3 else { return }
        lastReport = now
        let t = engine.telemetry
        let rigName = ["single", "2-projector", "4-projector"][rig]
        let fxName = effectIndex >= 0 ? EffectKind.allCases[effectIndex].name : "none"
        let line = String(
            format: "Photon · %d layers · %.0f fps · p50 %.2fms · GPU %.2fms · %@%@ · fx: %@ · blend: %@ · %@",
            t.activeLayers, t.fps, t.frameTimeP50, t.gpuTime,
            rigName, keystoned ? " + keystone" : "", fxName, topBlend.name,
            testPattern?.name ?? "deck q:\(engine.deck.quantise.name)")
        onStats?(line)
        // Also to stdout, so the demo can be verified headlessly (and in CI)
        // without depending on window enumeration or a screenshot.
        statTicks += 1
        if statTicks % 6 == 0 { print(line); fflush(stdout) }
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 126: layerCount = min(6, layerCount + 1); rebuild()
        case 125: layerCount = max(1, layerCount - 1); rebuild()
        case 11:
            let all = BlendMode.allCases
            topBlend = all[(all.firstIndex(of: topBlend)! + 1) % all.count]; rebuild()
        case 17:
            let patterns: [LayerKind?] = [nil, .testGrid, .testCrosshair, .testBars]
            let i = patterns.firstIndex { $0 == testPattern } ?? 0
            testPattern = patterns[(i + 1) % patterns.count]; rebuild()
        case 14:
            effectIndex = effectIndex + 1 >= EffectKind.allCases.count ? -1 : effectIndex + 1
            rebuild()
        case 1:  rig = (rig + 1) % 3; applyRig()
        case 40: keystoned.toggle(); applyRig()
        case 8:  trimmed.toggle(); applyRig()
        case 46: useMedia.toggle(); rebuild()
        case 15: keystoned = false; trimmed = false; rig = 0; applyRig()
        // Number keys 1-8 fire grid columns, quantised to the bar.
        case 18, 19, 20, 21, 23, 22, 26, 28:
            let order: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28]
            if let col = order.firstIndex(of: e.keyCode) {
                testPattern = nil
                engine.patternKind = nil
                engine.triggerColumn(col)
            }
        case 24: // = : cycle quantisation
            let all = Quantise.allCases
            let i = all.firstIndex(of: engine.deck.quantise) ?? 0
            engine.deck.quantise = all[(i + 1) % all.count]
        case 49: engine.animateTransforms.toggle()
        case 12: NSApp.terminate(nil)
        default: super.keyDown(with: e)
        }
    }
}

extension DemoView: @preconcurrency CAMetalDisplayLinkDelegate {
    func metalDisplayLink(_ link: CAMetalDisplayLink,
                          needsUpdate update: CAMetalDisplayLink.Update) {
        draw(update.drawable)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 720)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "Photon"
        window.center()

        guard let v = DemoView.make() else {
            print("FATAL: no Metal device"); NSApp.terminate(nil); return
        }
        v.onStats = { [weak self] s in self?.window.title = s }
        window.contentView = v
        window.makeFirstResponder(v)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("""
        Photon engine demo.
          1-8  fire column   =  quantise       ↑ ↓  layers
          T    test pattern   S  rig: single / 2 / 4 projector
          B    blend mode    K  keystone       C  colour-trim projector 1
          E    effect        M  media on/off   R  reset mapping
          Space pause motion                   Q  quit
        """)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
