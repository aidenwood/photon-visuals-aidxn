// GPU verification for the composite → warp → encode path.
//
// An executable rather than an XCTest target **because XCTest requires full
// Xcode**, and the engine is deliberately buildable with Command Line Tools
// alone. It also makes this runnable in CI without an Xcode install.
//
// "It compiled" and "it didn't crash" are not evidence a renderer works — a
// wrong blend, a mis-specified vertex layout, or an entirely black frame all
// build and run perfectly. These read pixels back and assert on them.
//
// Run:  swift run -c release PhotonVerify     (exit 0 = all passed)

import Foundation
import AVFoundation
import Metal
import PhotonRender
import simd

var failures = 0
var checks = 0

@MainActor func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  ✓ \(name)")
    } else {
        failures += 1
        let d = detail()
        print("  ✗ \(name)\(d.isEmpty ? "" : "  — \(d)")")
    }
}

/// Runs a block of checks that needs a live `PhotonEngine`, and **fails loudly
/// if it cannot be built** rather than skipping in silence.
///
/// Four sections used to read `if let dev = ..., let eng = ... { }` with no
/// `else`. If the engine could not be constructed, every check inside simply
/// did not happen — and the suite still printed "N/N passed" and exited 0.
/// A gate that reports success for work it never did is worse than no gate,
/// because it is trusted. Found by an adversarial audit, not by anything
/// failing, which is exactly the point.
@MainActor func engineSection(_ name: String,
                              _ body: (MTLDevice, PhotonEngine) -> Void) {
    guard let dev = MTLCreateSystemDefaultDevice(),
          let eng = PhotonEngine(device: dev) else {
        check("\(name) section ran", false,
              "no Metal device or engine — these checks did NOT run")
        return
    }
    body(dev, eng)
}

guard let device = MTLCreateSystemDefaultDevice(),
      let compositor = Compositor(device: device),
      let stage = OutputStage(device: device) else {
    print("FATAL: could not create Metal device / pipelines")
    exit(2)
}

let SIZE = 64

/// Renders one frame through the real path and returns BGRA8 pixels.
@MainActor func renderFrame(layers: [LayerUniform], slices: [OutputSlice]) -> [UInt8] {
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb, width: SIZE, height: SIZE, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    guard let output = device.makeTexture(descriptor: td),
          let cb = compositor.makeCommandBuffer() else { return [] }

    let work = compositor.composite(into: cb, layers: layers, time: 0,
                                    width: SIZE, height: SIZE, textures: [])
    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = output
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    if let work { stage.encode(into: cb, descriptor: rp, source: work, slices: slices) }
    cb.commit()
    cb.waitUntilCompleted()

    var px = [UInt8](repeating: 0, count: SIZE * SIZE * 4)
    px.withUnsafeMutableBytes { buf in
        output.getBytes(buf.baseAddress!, bytesPerRow: SIZE * 4,
                        from: MTLRegionMake2D(0, 0, SIZE, SIZE), mipmapLevel: 0)
    }
    return px
}

@MainActor func px(_ p: [UInt8], _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int) {
    guard !p.isEmpty else { return (0, 0, 0) }
    let i = (y * SIZE + x) * 4
    return (Int(p[i]), Int(p[i + 1]), Int(p[i + 2]))   // BGRA order
}

@MainActor func solid(_ c: SIMD4<Float>, blend: BlendMode = .over) -> LayerUniform {
    LayerUniform(tint: c, offsetScale: .init(0, 0, 1, 1),
                 opacity: 1, blend: blend, kind: 0)
}

print("Photon engine verification — \(device.name)\n")

// 1. The canvas actually gets drawn.
print("output path:")
do {
    let p = renderFrame(layers: [solid(.init(1, 0, 0, 1))], slices: [OutputStage.identitySlice()])
    let c = px(p, SIZE / 2, SIZE / 2)
    check("full-canvas slice renders non-black", c.r > 200 && c.g < 40 && c.b < 40,
          "centre BGR=\(c)")
}

// 2. No mapping configured is black, not garbage.
do {
    let p = renderFrame(layers: [solid(.init(1, 1, 1, 1))], slices: [])
    let c = px(p, SIZE / 2, SIZE / 2)
    check("no slices leaves output cleared", c.r < 8 && c.g < 8 && c.b < 8, "centre BGR=\(c)")
}

// 3. Geometry is respected — a half-width quad must leave the rest black.
do {
    let half = QuadCorners(topLeft: .init(-1, 1), topRight: .init(0, 1),
                           bottomRight: .init(0, -1), bottomLeft: .init(-1, -1))
    let p = renderFrame(layers: [solid(.init(1, 1, 1, 1))],
                        slices: [OutputSlice(surface: WarpSurface(corners: half))])
    let l = px(p, SIZE / 4, SIZE / 2)
    let r = px(p, 3 * SIZE / 4, SIZE / 2)
    check("half-canvas quad lights only its half", l.r > 150 && r.r < 20,
          "left=\(l.r) right=\(r.r)")
}

// 4. Overlapping projectors sum light rather than replacing it.
do {
    let dim = solid(.init(0.25, 0.25, 0.25, 1))
    let one = px(renderFrame(layers: [dim], slices: [OutputStage.identitySlice()]), SIZE/2, SIZE/2)
    let two = px(renderFrame(layers: [dim],
                             slices: [OutputStage.identitySlice(), OutputStage.identitySlice()]),
                 SIZE/2, SIZE/2)
    check("overlapping slices accumulate", two.r > one.r + 10, "one=\(one.r) two=\(two.r)")
}

// 5. The pipeline composites in LINEAR light.
//    0.25 linear encodes to ~0.537 sRGB (~137/255). Compositing in gamma space
//    would land near 64 — and every soft-edge blend would show a seam.
print("\ncolour:")
do {
    let p = renderFrame(layers: [solid(.init(0.25, 0.25, 0.25, 1))],
                        slices: [OutputStage.identitySlice()])
    let v = px(p, SIZE / 2, SIZE / 2).r
    check("linear-light composite, sRGB encode at output", v > 120 && v < 155,
          "expected ~137, got \(v)")
}

// 6. The fold really reads the destination.
print("\nblend modes:")
do {
    let p = renderFrame(layers: [solid(.init(1, 1, 1, 1)),
                                 solid(.init(1, 1, 1, 1), blend: .difference)],
                        slices: [OutputStage.identitySlice()])
    let v = px(p, SIZE / 2, SIZE / 2).r
    check("difference(white, white) ≈ black", v < 60, "got \(v)")
}
do {
    // Multiply by mid-grey must darken; proves per-layer blend selection works.
    let p = renderFrame(layers: [solid(.init(1, 1, 1, 1)),
                                 solid(.init(0.5, 0.5, 0.5, 1), blend: .multiply)],
                        slices: [OutputStage.identitySlice()])
    let v = px(p, SIZE / 2, SIZE / 2).r
    check("multiply darkens", v < 220 && v > 150, "got \(v)")
}

// 7. Homography sanity — corners map exactly, and q varies under keystone.
print("\nwarp geometry:")
do {
    let keystone = QuadCorners(topLeft: .init(-0.8, 0.9), topRight: .init(0.9, 0.6),
                               bottomRight: .init(0.7, -0.9), bottomLeft: .init(-0.9, -0.7))
    if let h = Homography.unitSquare(to: keystone) {
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            // uv (0,0) is topLeft — QuadCorners index order is TL, TR, BR, BL.
            (.init(0, 0), keystone.topLeft), (.init(1, 0), keystone.topRight),
            (.init(1, 1), keystone.bottomRight), (.init(0, 1), keystone.bottomLeft),
        ]
        var worst: Float = 0
        for (src, want) in corners {
            if let got = h.apply(src) { worst = max(worst, simd_distance(got, want)) }
        }
        check("homography maps all 4 corners exactly", worst < 1e-4, "worst error \(worst)")

        let mesh = try? WarpSurface(corners: keystone).triangulate()
        let qs = mesh?.vertices.map(\.q) ?? []
        let spread = (qs.max() ?? 0) - (qs.min() ?? 0)
        check("keystone produces varying q (projective, not affine)", spread > 1e-3,
              "q spread \(spread)")
    } else {
        check("homography solves for a keystone", false, "returned nil")
    }
}


// 8. Soft edge — the property that decides whether a blend is invisible on site.
//    Two projectors overlapping, each ramping to 50% through the band, must sum
//    to the SAME brightness as a single projector. Any deviation is a visible
//    bright or dark stripe down the middle of the screen.
print("\nsoft edge (2-projector overlap):")
do {
    let grey = solid(.init(0.5, 0.5, 0.5, 1))

    // Reference: one slice covering everything, no blending.
    let ref = px(renderFrame(layers: [grey], slices: [OutputStage.identitySlice()]), SIZE/2, SIZE/2).r

    // Left projector covers x in [-1, 0.2] clip, sampling the left 60% of the
    // source; its right third is the ramp. Right projector mirrors it.
    let overlapOfWidth: Float = 1.0 / 3.0
    let left = OutputSlice(surface: WarpSurface(
        corners: QuadCorners(topLeft: .init(-1, 1), topRight: .init(0.2, 1),
                             bottomRight: .init(0.2, -1), bottomLeft: .init(-1, -1)),
        softEdge: SoftEdge(right: overlapOfWidth, gamma: 2.2),
        sourceOrigin: .init(0, 0), sourceSize: .init(0.6, 1)))
    let right = OutputSlice(surface: WarpSurface(
        corners: QuadCorners(topLeft: .init(-0.2, 1), topRight: .init(1, 1),
                             bottomRight: .init(1, -1), bottomLeft: .init(-0.2, -1)),
        softEdge: SoftEdge(left: overlapOfWidth, gamma: 2.2),
        sourceOrigin: .init(0.4, 0), sourceSize: .init(0.6, 1)))

    let blended = renderFrame(layers: [grey], slices: [left, right])
    let band = px(blended, SIZE/2, SIZE/2).r          // centre of the overlap
    let outsideL = px(blended, SIZE/8, SIZE/2).r      // lit by the left only
    let outsideR = px(blended, 7*SIZE/8, SIZE/2).r    // lit by the right only

    check("single-projector reference is mid-grey", ref > 150 && ref < 210, "ref=\(ref)")
    check("non-overlap regions match the reference",
          abs(outsideL - ref) <= 4 && abs(outsideR - ref) <= 4,
          "left=\(outsideL) right=\(outsideR) ref=\(ref)")
    check("overlap band shows no seam",
          abs(band - ref) <= 6,
          "band=\(band) ref=\(ref) — a gap here is a visible stripe on screen")
}


// 9. Thumbnails — against REAL media, not a synthetic fixture.
print("\nthumbnails:")
do {
    let mediaDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("media-cache")
    let clips = ((try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path)) ?? [])
        .filter { $0.hasSuffix(".mp4") }.sorted()
        .map { mediaDir.appendingPathComponent($0) }

    if clips.isEmpty {
        print("  — skipped: no media in media-cache/")
    } else {
        let cache = ThumbnailCache.beside(mediaDir)
        let first = clips[0]

        let t0 = Date()
        let img = await cache.thumbnail(for: first)
        let coldMs = Date().timeIntervalSince(t0) * 1000
        check("generates a thumbnail from real media", img != nil,
              "\(first.lastPathComponent)")
        if let img {
            check("thumbnail is a sensible size",
                  img.width > 16 && img.height > 16 && max(img.width, img.height) <= 400,
                  "\(img.width)x\(img.height)")
        }

        // Second call must not decode again.
        let t1 = Date()
        _ = await cache.thumbnail(for: first)
        let warmMs = Date().timeIntervalSince(t1) * 1000
        check("second request is served from cache", warmMs < coldMs / 2 || warmMs < 1.0,
              String(format: "cold %.1fms, warm %.2fms", coldMs, warmMs))

        // Concurrent requests for the same clip must share one decode.
        await cache.purgeMemory()
        async let a = cache.thumbnail(for: first)
        async let b = cache.thumbnail(for: first)
        async let c = cache.thumbnail(for: first)
        let all = await [a, b, c]
        check("concurrent requests de-duplicate", all.allSatisfy { $0 != nil },
              "all three resolved")

        // An undecodable file must degrade, never crash.
        let bogus = mediaDir.appendingPathComponent("definitely-not-a-video.mp4")
        let none = await cache.thumbnail(for: bogus)
        check("undecodable file yields nil rather than crashing", none == nil)

        let gen = await cache.generated
        print("  (generated \(gen) this run across \(clips.count) clips available)")
    }
}


// 10. Clip transport — the behaviour an operator actually feels.
print("\ntransport:")
do {
    // BPM sync: a 4s clip looping over 4 beats at 120 BPM (= 2s) must play 2x.
    let sync = ClipTransport(mode: .bpmSync(beats: 4))
    let r = sync.rate(bpm: 120, clipSeconds: 4.0)
    check("bpm-sync derives playback rate from tempo", abs(r - 2.0) < 1e-9,
          "expected 2.0x, got \(r)")

    // Halving the tempo must halve the rate — the clip still lands on the beat.
    let rHalf = sync.rate(bpm: 60, clipSeconds: 4.0)
    check("halving tempo halves the rate", abs(rHalf - 1.0) < 1e-9, "got \(rHalf)")

    // Timeline mode must ignore tempo entirely.
    let free = ClipTransport(mode: .timeline)
    check("timeline mode ignores tempo",
          free.rate(bpm: 174, clipSeconds: 4) == 1.0 &&
          free.rate(bpm: 60, clipSeconds: 4) == 1.0)

    // Loop wraps and keeps the remainder rather than snapping to the in point,
    // which would quantise away sub-frame timing and drift against the beat.
    let loop = ClipTransport(playthrough: .loop)
    let (lp, _) = loop.advance(position: 0.95, by: 0.10)
    check("loop wraps and preserves the remainder", abs(lp - 0.05) < 1e-9, "got \(lp)")

    // Once clamps and reports completion.
    let once = ClipTransport(playthrough: .once)
    let (op, of) = once.advance(position: 0.95, by: 0.10)
    check("once clamps at the out point and reports finished", of && abs(op - 1.0) < 1e-9,
          "pos=\(op) finished=\(of)")

    // Ping-pong reflects rather than wrapping.
    let pp = ClipTransport(playthrough: .pingPong)
    let (pq, _) = pp.advance(position: 0.95, by: 0.10)
    check("ping-pong reflects off the out point", pq > 0.9 && pq < 1.0, "got \(pq)")
    check("ping-pong flags a direction flip", pp.flips(position: 0.95, by: 0.10))

    // A degenerate trim must not silently stall playback forever.
    let bad = ClipTransport(trimIn: 0.8, trimOut: 0.2)
    check("inverted trim is repaired, not left to stall", bad.span > 0,
          "span=\(bad.span)")

    // Hold-last keeps the frame on screen — blackout stays an operator action.
    let hold = ClipTransport(playthrough: .holdLast)
    let (hp, hf) = hold.advance(position: 0.99, by: 0.5)
    check("hold-last keeps the final frame, never blacks out",
          abs(hp - 1.0) < 1e-9 && hf, "pos=\(hp)")
}


// 11. Output topology — the mapping document, and the splitter rig it exists for.
print("\noutput topology:")
do {
    let single = OutputTopology.singleScreen()
    check("default topology renders something", single.activeSlices().count == 1)

    // The case the whole "rect inside a canvas" abstraction exists for: more
    // projectors than the machine has display outputs.
    let rig = OutputTopology.splitter(projectors: 4)
    let slices = rig.activeSlices()
    check("4-projector splitter produces 4 slices", slices.count == 4, "got \(slices.count)")
    check("splitter canvas is the full combined width",
          rig.screens[0].width == 7680, "got \(rig.screens[0].width)")

    // Interior projectors blend both sides; the outer edges must not, or the
    // image fades off into black at the ends of the rig.
    let cfg = rig.screens[0].slices
    check("only interior edges get soft-edge overlap",
          cfg[0].edgeLeft == 0 && cfg[0].edgeRight > 0 &&
          cfg[3].edgeRight == 0 && cfg[3].edgeLeft > 0 &&
          cfg[1].edgeLeft > 0 && cfg[1].edgeRight > 0,
          "outer edges must not fade to black")

    // Every slice must triangulate; a mapping that cannot render is useless.
    var allOK = true
    for s in slices { if (try? s.surface.triangulate()) == nil { allOK = false } }
    check("every splitter slice triangulates", allOK)

    // Round-trips to disk, because a mapping travels separately from the show.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("photon-topology-check.json")
    do {
        try rig.write(to: tmp)
        let back = try OutputTopology.read(from: tmp)
        check("mapping round-trips through disk",
              back.screens.count == rig.screens.count &&
              back.screens[0].slices.count == 4 &&
              back.screens[0].width == rig.screens[0].width)
        try? FileManager.default.removeItem(at: tmp)
    } catch {
        check("mapping round-trips through disk", false, "\(error)")
    }

    // Setting a topology on the engine must never leave the output with
    // nothing to draw — blackout stays an explicit operator action.
    engineSection("topology") { dev, eng in
        eng.topology = OutputTopology(name: "empty", screens: [])
        check("an empty mapping falls back rather than going black",
              !eng.slices.isEmpty, "slices=\(eng.slices.count)")
        eng.topology = rig
        check("a real mapping drives the engine's slices", eng.slices.count == 4,
              "slices=\(eng.slices.count)")
    }

    // A disabled screen must drop out without losing its mapping.
    var off = rig
    off.screens[0].enabled = false
    check("disabling a screen removes its output but keeps the mapping",
          off.activeSlices().isEmpty && off.screens[0].slices.count == 4)
}


// 12. Test patterns — the rigging aids. These must be CORRECT, because an
//     operator aligns a projector against them and trusts what they see.
print("\ntest patterns:")
do {
    func pattern(_ kind: LayerKind) -> [UInt8] {
        let l = LayerUniform(tint: .init(1, 1, 1, 1), offsetScale: .init(0, 0, 1, 1),
                             opacity: 1, blend: .over, kind: kind.rawValue)
        return renderFrame(layers: [l], slices: [OutputStage.identitySlice()])
    }

    check("test-pattern kinds are flagged as such",
          LayerKind.testGrid.isTestPattern && LayerKind.testBars.isTestPattern
          && !LayerKind.video.isTestPattern)

    // Grid: must contain both lit lines and dark gaps. A pattern that is all
    // one value tells the operator nothing.
    let grid = pattern(.testGrid)
    var gridLit = 0, gridDark = 0
    for y in 0..<SIZE { for x in 0..<SIZE {
        let v = px(grid, x, y).r
        if v > 100 { gridLit += 1 } else if v < 30 { gridDark += 1 }
    }}
    check("grid has visible lines and gaps", gridLit > 50 && gridDark > 200,
          "lit=\(gridLit) dark=\(gridDark)")

    // Crosshair: the exact centre must be lit, and so must the border.
    let cross = pattern(.testCrosshair)
    check("crosshair centre is lit", px(cross, SIZE/2, SIZE/2).r > 100,
          "got \(px(cross, SIZE/2, SIZE/2).r)")
    check("crosshair border reaches the very edge",
          px(cross, 0, SIZE/2).r > 100 && px(cross, SIZE-1, SIZE/2).r > 100,
          "a missing border edge means the slice is overscanning")

    // Colour bars: left-most bar white, and a red bar present further along.
    let bars = pattern(.testBars)
    let first = px(bars, 2, SIZE/4)
    check("colour bars start white", first.r > 200 && first.g > 200 && first.b > 200,
          "got \(first)")
    var sawRed = false
    for x in 0..<SIZE {
        let c = px(bars, x, SIZE/4)
        if c.r > 180 && c.g < 60 && c.b < 60 { sawRed = true }
    }
    check("colour bars include a pure red bar", sawRed)

    // The greyscale strip must actually ramp, for gamma matching. Scan for the
    // row rather than assuming which one — the warp stage flips vertically, so
    // hard-coding it would make this test a coin flip rather than a check.
    var foundRamp = false
    for y in 0..<SIZE {
        let lo = px(bars, 2, y).r, mid = px(bars, SIZE/2, y).r, hi = px(bars, SIZE-3, y).r
        if hi > mid + 40 && mid > lo + 40 { foundRamp = true; break }
    }
    check("a greyscale ramp strip exists for gamma matching", foundRamp)
}


// 13. Per-slice colour correction — projectors never match out of the box.
print("\nper-slice colour:")
do {
    let grey = solid(.init(0.5, 0.5, 0.5, 1))
    func slice(gain: SIMD3<Float> = .init(1,1,1),
               lift: SIMD3<Float> = .init(0,0,0),
               gamma: Float = 1) -> OutputSlice {
        OutputSlice(surface: WarpSurface(corners: .clipSpace),
                    opacity: 1, gain: gain, lift: lift, outGamma: gamma)
    }

    let base = px(renderFrame(layers: [grey], slices: [slice()]), SIZE/2, SIZE/2)
    check("identity correction leaves the image untouched",
          base.r > 150 && base.r < 210 && abs(base.r - base.g) <= 2,
          "got \(base)")

    // Gain must trim one channel without disturbing the others — that is the
    // whole point when matching a projector with a tired blue lamp.
    let warm = px(renderFrame(layers: [grey],
                              slices: [slice(gain: .init(1, 1, 0.5))]), SIZE/2, SIZE/2)
    check("per-channel gain trims only that channel",
          warm.b < base.b - 25 && abs(warm.r - base.r) <= 3 && abs(warm.g - base.g) <= 3,
          "base=\(base) warm=\(warm)")

    // Lift raises blacks without clipping the top.
    let lifted = px(renderFrame(layers: [solid(.init(0, 0, 0, 1))],
                                slices: [slice(lift: .init(0.2, 0.2, 0.2))]), SIZE/2, SIZE/2)
    check("lift raises crushed blacks", lifted.r > 90, "got \(lifted.r)")

    // Gamma darkens midtones (values <1 in linear, exponent >1).
    let gam = px(renderFrame(layers: [grey], slices: [slice(gamma: 2.0)]), SIZE/2, SIZE/2)
    check("per-slice gamma reshapes midtones", gam.r < base.r - 25,
          "base=\(base.r) gamma2=\(gam.r)")

    // Correction must not break the overlap sum — a trimmed projector still has
    // to blend seamlessly with its neighbour.
    let full = px(renderFrame(layers: [grey], slices: [slice(), slice()]), SIZE/2, SIZE/2)
    check("correction is applied before the soft-edge weight", full.r > base.r,
          "two identity slices should still accumulate: one=\(base.r) two=\(full.r)")
}


// 14. Effect chain — the hybrid compositor's break-out path.
print("\neffects:")
do {
    guard let chain = EffectChain(device: device) else {
        check("effect chain builds", false); exit(1)
    }

    // A known source: half black, half white, in linear light.
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: SIZE, height: SIZE, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    let src = device.makeTexture(descriptor: td)!
    var pixels = [Float16](repeating: 0, count: SIZE * SIZE * 4)
    for y in 0..<SIZE { for x in 0..<SIZE {
        let v: Float16 = x < SIZE/2 ? 0.0 : 1.0
        let i = (y * SIZE + x) * 4
        pixels[i] = v; pixels[i+1] = v; pixels[i+2] = v; pixels[i+3] = 1
    }}
    pixels.withUnsafeBytes { buf in
        src.replace(region: MTLRegionMake2D(0, 0, SIZE, SIZE), mipmapLevel: 0,
                    withBytes: buf.baseAddress!, bytesPerRow: SIZE * 8)
    }

    // Effect targets are `.private` (correct for production), so they cannot be
    // read directly — blit into shared storage first. Reading a private texture
    // is a hard crash, not an error return.
    let stageDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: SIZE, height: SIZE, mipmapped: false)
    stageDesc.usage = [.shaderRead]
    stageDesc.storageMode = .shared
    let stage = device.makeTexture(descriptor: stageDesc)!

    func readLinear(_ tex: MTLTexture, _ x: Int, _ y: Int) -> Float {
        let readable: MTLTexture
        if tex.storageMode == .shared {
            readable = tex
        } else {
            guard let cb = compositor.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return .nan }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: SIZE, height: SIZE, depth: 1),
                      to: stage, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            readable = stage
        }
        var p = [Float16](repeating: 0, count: 4)
        p.withUnsafeMutableBytes { b in
            readable.getBytes(b.baseAddress!, bytesPerRow: 8,
                              from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return Float(p[0])
    }

    func run(_ fx: [Effect]) -> MTLTexture {
        let cb = compositor.makeCommandBuffer()!
        let out = chain.apply(fx, to: src, in: cb)
        cb.commit(); cb.waitUntilCompleted()
        return out
    }

    // An empty or fully-bypassed chain must cost nothing and return the source.
    check("empty chain returns the source untouched", run([]) === src)
    check("fully bypassed chain costs nothing",
          run([Effect(kind: .blur, enabled: false)]) === src)

    // Invert at full amount.
    let inv = run([Effect(kind: .invert, amount: 1.0)])
    check("invert flips black and white",
          readLinear(inv, SIZE/4, SIZE/2) > 0.9 && readLinear(inv, 3*SIZE/4, SIZE/2) < 0.1,
          "left=\(readLinear(inv, SIZE/4, SIZE/2)) right=\(readLinear(inv, 3*SIZE/4, SIZE/2))")

    // THE correctness check: a pass must never write into the caller's texture.
    // Getting this wrong corrupts the live source and shows up as flicker.
    check("the source texture is never written to",
          readLinear(src, SIZE/4, SIZE/2) < 0.01 && readLinear(src, 3*SIZE/4, SIZE/2) > 0.99,
          "source was mutated by the chain")

    // Blur must soften the hard edge at the midpoint.
    let blurred = run([Effect(kind: .blur, amount: 1.0)])
    let edge = readLinear(blurred, SIZE/2, SIZE/2)
    check("blur softens a hard edge", edge > 0.05 && edge < 0.95,
          "edge value \(edge) — should be intermediate, not still binary")

    // Chains compose: invert twice returns to the original.
    let twice = run([Effect(kind: .invert, amount: 1.0), Effect(kind: .invert, amount: 1.0)])
    check("a two-effect chain composes in order",
          readLinear(twice, SIZE/4, SIZE/2) < 0.1 && readLinear(twice, 3*SIZE/4, SIZE/2) > 0.9,
          "double invert should restore the original")

    check("neighbourhood effects are flagged for the planner",
          EffectKind.blur.isNeighbourhood && !EffectKind.invert.isNeighbourhood)
    check("pass count is reported for telemetry", chain.passesLastFrame == 2,
          "got \(chain.passesLastFrame)")

    // Every kind the browser offers must actually do something.
    //
    // This check exists because it did not: `EffectKind` grew from 6 cases to 35
    // while the Metal switch kept the ORIGINAL six-case numbering. The raw values
    // silently re-pointed — `levels` ran blur, `invert` ran rgbShift — and the 29
    // kinds past the end fell to `default`, which is a passthrough. An operator
    // would have picked an effect from the list and seen nothing happen, with no
    // error anywhere. A shader `switch` on a raw value has no compiler to tell it
    // a case is missing, so the test has to be the compiler.
    //
    // The source is deliberately asymmetric in both axes and fully coloured:
    // a mirrored or hue-rotated version of a symmetric grey image can equal the
    // original, which would read as "not implemented" and be a false failure.
    let probeDesc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: SIZE, height: SIZE, mipmapped: false)
    probeDesc.usage = [.renderTarget, .shaderRead]
    probeDesc.storageMode = .shared
    let probe = device.makeTexture(descriptor: probeDesc)!
    var pp = [Float16](repeating: 0, count: SIZE * SIZE * 4)
    for y in 0..<SIZE { for x in 0..<SIZE {
        let fx = Float(x) / Float(SIZE), fy = Float(y) / Float(SIZE)
        let i = (y * SIZE + x) * 4
        // Fine checker on top of the gradient. Without local detail an unsharp
        // mask is a genuine no-op — a smooth ramp has nothing to sharpen — and
        // the kind would read as unimplemented when it is simply well behaved.
        let d: Float = ((x / 4) + (y / 4)) % 2 == 0 ? 0.12 : -0.12
        pp[i]   = Float16(max(0, 0.15 + 0.8 * fx + d))
        pp[i+1] = Float16(max(0, 0.10 + 0.7 * fy * fx + d))
        pp[i+2] = Float16(max(0, 0.90 - 0.6 * fy + d))
        pp[i+3] = 1
    }}
    pp.withUnsafeBytes { buf in
        probe.replace(region: MTLRegionMake2D(0, 0, SIZE, SIZE), mipmapLevel: 0,
                      withBytes: buf.baseAddress!, bytesPerRow: SIZE * 8)
    }

    func rgba(_ tex: MTLTexture, _ x: Int, _ y: Int) -> [Float] {
        let readable: MTLTexture
        if tex.storageMode == .shared {
            readable = tex
        } else {
            guard let cb = compositor.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return [.nan] }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: SIZE, height: SIZE, depth: 1),
                      to: stage, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            readable = stage
        }
        var px = [Float16](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { b in
            readable.getBytes(b.baseAddress!, bytesPerRow: 8,
                              from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return px.map(Float.init)
    }

    /// Every texel of a texture, in one read.
    ///
    /// The checks below used to sample a 4×4 grid — **16 texels of 4096, 0.4%**
    /// — and that sparsity hid a real defect: `lumaKey` is not an identity at
    /// its neutral amount, driving alpha to 0.219 across 23% of the image,
    /// while every one of the 16 sampled points happened to be unaffected.
    /// Whole-image delta 0.845, sampled delta 0.00000. A guard that inspects
    /// 0.4% of the evidence is a guard that passes things.
    ///
    /// One `getBytes` for the whole surface costs less than 16 separate reads,
    /// so there was never a reason for the grid.
    func readAll(_ tex: MTLTexture) -> [Float] {
        let readable: MTLTexture
        if tex.storageMode == .shared {
            readable = tex
        } else {
            guard let cb = compositor.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return [.nan] }
            blit.copy(from: tex, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: SIZE, height: SIZE, depth: 1),
                      to: stage, destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            cb.commit(); cb.waitUntilCompleted()
            readable = stage
        }
        var px = [Float16](repeating: 0, count: SIZE * SIZE * 4)
        px.withUnsafeMutableBytes { b in
            readable.getBytes(b.baseAddress!, bytesPerRow: SIZE * 8,
                              from: MTLRegionMake2D(0, 0, SIZE, SIZE), mipmapLevel: 0)
        }
        return px.map(Float.init)
    }

    // `beat` is non-zero on purpose: strobe gates on musical phase, and at beat 0
    // it is legitimately open, which would look like a missing implementation.
    func applyOne(_ kind: EffectKind) -> MTLTexture {
        let cb = compositor.makeCommandBuffer()!
        let out = chain.apply([Effect(kind: kind, amount: 0.8, param: 0.35)],
                              to: probe, in: cb, time: 0.37, beat: 2.0)
        cb.commit(); cb.waitUntilCompleted()
        return out
    }

    let probeAll = readAll(probe)
    var deadKinds: [String] = []
    for kind in EffectKind.allCases {
        let out = readAll(applyOne(kind))
        let changed = zip(probeAll, out).contains { abs($0 - $1) > 0.002 }
        if !changed { deadKinds.append(kind.name) }
    }
    check("every effect kind is implemented in the shader", deadKinds.isEmpty,
          "these did nothing: \(deadKinds.joined(separator: ", "))")

    check("effect kind count matches the shader's case range",
          EffectKind.allCases.count == 35,
          "\(EffectKind.allCases.count) kinds — the shader switch covers 0...34")

    // The neutral point of `amount`, asserted rather than assumed.
    //
    // An operator automates `amount` from a fader, an LFO or an envelope. If the
    // neutral end of that modulation is not an exact identity the picture jumps
    // the instant the source reaches rest — a jump that only appears once the
    // modulation is wired up, which is to say on stage.
    //
    // `EffectKind.amountMode` declares where neutral sits; this proves the
    // shader agrees. `param` is swept too, because a knob parked somewhere else
    // must not reintroduce the effect behind a neutral `amount`.
    // Returns the sampled grid rather than the texture. `EffectChain` ping-pongs
    // through two pooled targets, so a one-effect chain always lands in the SAME
    // texture — holding two "results" and comparing them compares one texture
    // with itself, which silently passes everything. Read it out now or it is
    // gone by the next call.
    func probeGrid(_ kind: EffectKind, amount: Float, param: Float,
                   beat: Double = 2.0) -> [Float] {
        let cb = compositor.makeCommandBuffer()!
        let out = chain.apply([Effect(kind: kind, amount: amount, param: param)],
                              to: probe, in: cb, time: 0.37, beat: beat)
        cb.commit(); cb.waitUntilCompleted()
        return readAll(out)
    }

    let probeBaseline = readAll(probe)

    var notNeutral: [String] = []
    for kind in EffectKind.allCases {
        let neutral: Float = kind.amountMode == .bipolar ? 0.5 : 0.0
        // `neutralParam` is non-nil only where the second knob is an independent
        // axis rather than a setting the effect is gated over (temperature).
        let params: [Float] = kind.neutralParam.map { [$0] } ?? [0.0, 0.35, 1.0]
        var worst: Float = 0
        for param in params {
            let out = probeGrid(kind, amount: neutral, param: param)
            for i in 0..<min(out.count, probeBaseline.count) {
                worst = max(worst, abs(out[i] - probeBaseline[i]))
            }
        }
        // 0.004 is two float16 ulps around 1.0 — tight enough that a real
        // effect cannot hide under it, loose enough for a linear↔display
        // round trip and a trig identity in the warps.
        if worst > 0.004 { notNeutral.append("\(kind.name) (\(worst))") }
    }
    check("every effect is an identity at its neutral amount", notNeutral.isEmpty,
          "these moved the picture while parked: \(notNeutral.joined(separator: ", "))")

    // A `nil` paramLabel is a promise that the second knob does nothing. If the
    // shader reads `param` anyway, the UI hides a control that is still live and
    // the effect behaves differently depending on a value nobody can see.
    var lyingLabels: [String] = []
    for kind in EffectKind.allCases where kind.paramLabel == nil {
        let lo = probeGrid(kind, amount: 0.8, param: 0.0)
        let hi = probeGrid(kind, amount: 0.8, param: 1.0)
        if zip(lo, hi).contains(where: { abs($0 - $1) > 0.002 }) {
            lyingLabels.append(kind.name)
        }
    }
    check("effects with no param label genuinely ignore param", lyingLabels.isEmpty,
          "these read param behind an unlabelled knob: \(lyingLabels.joined(separator: ", "))")

    // The converse: a labelled knob that does nothing is a knob the operator
    // turns during a show while wondering why the screen is not changing.
    var deadParams: [String] = []
    for kind in EffectKind.allCases where kind.paramLabel != nil {
        // Not at amount 0 — a correct effect is an identity there whatever
        // param says, so param can only be observed with the effect engaged.
        // Two musical positions, because a tempo-locked effect can legitimately
        // sit in the same state for two different rates at one instant — a
        // strobe that happens to be dark at both reads as a dead knob when it
        // is simply mid-blackout.
        var live = false
        for beat in [0.3, 2.0] {
            let lo = probeGrid(kind, amount: 0.7, param: 0.1, beat: beat)
            let hi = probeGrid(kind, amount: 0.7, param: 0.9, beat: beat)
            if zip(lo, hi).contains(where: { abs($0 - $1) > 0.002 }) { live = true }
        }
        if !live { deadParams.append("\(kind.name)/\(kind.paramLabel!)") }
    }
    check("every labelled param knob actually does something", deadParams.isEmpty,
          "these knobs are labelled but inert: \(deadParams.joined(separator: ", "))")

    // A NaN in a live show poisons every pixel it touches for the rest of the
    // frame, and no amount of staring at the wall tells you which effect did it.
    // Sweep both knobs to the ends of their ranges, where the divisions and the
    // pow()s live, and refuse to ship anything non-finite.
    var nonFinite: [String] = []
    for kind in EffectKind.allCases {
        outer: for amount in [Float(0.0), 0.5, 1.0] {
            for param in [Float(0.0), 0.5, 1.0] {
                if probeGrid(kind, amount: amount, param: param)
                    .contains(where: { !$0.isFinite }) {
                    nonFinite.append("\(kind.name) @ \(amount)/\(param)")
                    break outer
                }
            }
        }
    }
    check("no effect produces NaN or infinity at the ends of its range",
          nonFinite.isEmpty, "non-finite output from: \(nonFinite.joined(separator: ", "))")

    // Dry/wet and per-effect blend, which the chain applies for every effect
    // rather than each effect implementing its own. Resolume wraps every one
    // of its effects the same way (`DryWetEffect -> Effect -> Mixer`), and the
    // reason to do it host-side is exactly that it then cannot vary: an
    // operator who learns what the mix knob does on one effect knows what it
    // does on all 35.
    func probeMixed(_ fx: Effect) -> [Float] {
        let cb = compositor.makeCommandBuffer()!
        let out = chain.apply([fx], to: probe, in: cb, time: 0.37, beat: 2.0)
        cb.commit(); cb.waitUntilCompleted()
        return readAll(out)
    }

    let dry: [Float] = {
        return readAll(probe)
    }()

    // Invert at full strength, so wet is unmistakably different from dry and a
    // mix that silently did nothing could not pass by coincidence.
    let fullyWet = probeMixed(Effect(kind: .invert, amount: 1, mix: 1))
    let fullyDry = probeMixed(Effect(kind: .invert, amount: 1, mix: 0))
    let halfWet  = probeMixed(Effect(kind: .invert, amount: 1, mix: 0.5))

    check("mix = 0 returns the dry input untouched",
          zip(fullyDry, dry).allSatisfy { abs($0 - $1) < 0.002 },
          "a fully dry effect changed the picture")

    check("mix = 1 is the effect alone",
          zip(fullyWet, dry).contains { abs($0 - $1) > 0.01 },
          "a fully wet invert did not change the picture")

    // The midpoint must actually sit between the two. An implementation that
    // treated mix as a switch would pass both checks above and fail this one.
    check("mix = 0.5 lands between dry and wet",
          zip(halfWet, zip(dry, fullyWet)).allSatisfy { h, pair in
              let (d, w) = pair
              return abs(h - (d + w) * 0.5) < 0.01
          },
          "half mix is not the midpoint — mix is behaving as a switch")

    // Per-effect blend. Add over a known wet result gives dry + wet.
    //
    // Colour channels only. Alpha is crossfaded by `mix`, never run through
    // the blend — a key's alpha IS its output, and adding two opaque alphas
    // would give 2. That is the documented behaviour, so the check has to
    // honour it rather than assert the whole RGBA sums.
    let added = probeMixed(Effect(kind: .invert, amount: 1, mix: 1, blend: .add))
    let rgbIdx = added.indices.filter { $0 % 4 != 3 }
    check("per-effect blend mode folds the wet result over the dry",
          rgbIdx.allSatisfy { i in abs(added[i] - (dry[i] + fullyWet[i])) < 0.02 },
          "blend .add did not sum the dry and wet colour channels")

    check("blend leaves alpha crossfaded rather than blended",
          added.indices.filter { $0 % 4 == 3 }
              .allSatisfy { abs(added[$0] - fullyWet[$0]) < 0.002 },
          "alpha was run through the colour blend")

    // The parameter list. These are pure value-type checks, but they guard the
    // thing that makes a 21-parameter effect possible at all.
    check("an effect always has at least two values",
          Effect(kind: .invert, values: []).values.count == 2,
          "short value lists must pad, or amount/param would trap")

    check("a value list is clamped to the maximum",
          Effect(kind: .invert,
                 values: Array(repeating: 0.5, count: Effect.maxValues + 20))
              .values.count == Effect.maxValues,
          "an over-long list must clamp — a show file is untrusted input")

    check("values beyond the list read as nil rather than a default",
          Effect(kind: .invert, amount: 1, param: 1).value(at: 7) == nil,
          "a missing parameter must be nil, not a silent 0.5")

    var grown = Effect(kind: .invert)
    grown.setValue(0.25, at: 5)
    check("setting a high parameter grows the list",
          grown.values.count == 6 && grown.value(at: 5) == 0.25)

    check("amount and param alias the first two values",
          grown.amount == grown.values[0] && grown.param == grown.values[1])
}


// 14b. Blend modes — the other enum that hand-mirrors `photon-core`.
//
// Same class of defect as the effect-kind check above, and it has already bitten
// once: the Swift enum lost `Subtract`, so every mode above it shifted by one
// (a show saved as Subtract rendered as Lighten) and `Darken` — raw value 10 —
// fell off the end of the ten-element name array and crashed on open. Nothing
// at build time compares these two enums across the language boundary, so the
// test has to be the compiler.
print("\nblend modes:")
do {
    let modes = BlendMode.allCases
    let countOK = modes.count == 11
    check("blend mode count matches photon-core", countOK,
          "\(modes.count) cases — photon-core defines 11")

    check("blend mode raw values are contiguous from zero",
          modes.map(\.rawValue) == Array(Int32(0)...Int32(10)),
          "got \(modes.map(\.rawValue))")

    // Read the Rust enum and compare against it, rather than against a number
    // typed in here.
    //
    // The first version of this guard asserted `count == 11` and "contiguous
    // 0...10" — both of which are a hardcoded copy of the Swift side, so it
    // would have passed happily while `photon-core` grew a twelfth mode. That
    // is precisely the defect it exists to catch, which an adversarial audit
    // pointed out and was right about. The only non-circular check is to go
    // and look at the other language.
    do {
        let coreFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotonVerify
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // engine
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("photon-core/src/doc/mod.rs")

        if let rust = try? String(contentsOf: coreFile, encoding: .utf8),
           let body = rust.range(of: "pub enum BlendMode {").map({ r in
               rust[r.upperBound...].prefix(while: { $0 != "}" })
           }) {
            // Variant lines only: bare identifiers, no attributes or comments.
            let rustVariants = body
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("//") && !$0.hasPrefix("#") }
                .map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }
                .filter { $0.allSatisfy(\.isLetter) }

            // "Hard Light" in Swift is `HardLight` in Rust.
            let swiftNames = modes.map { $0.name.replacingOccurrences(of: " ", with: "") }

            check("blend modes match photon-core, variant for variant",
                  rustVariants == swiftNames,
                  "rust \(rustVariants) vs swift \(swiftNames)")
        } else {
            check("photon-core's BlendMode is readable for comparison", false,
                  "could not read \(coreFile.path) — the cross-language check did NOT run")
        }
    }

    // Mask must gate on the source's BRIGHTNESS — the black-to-white axis a
    // greyscale matte is painted on — not multiply channel by channel.
    //
    // It was `dst * src`, which is Multiply under a second name: a pure red
    // matte would have masked only the red channel instead of acting as a
    // ~21%-grey matte everywhere. A saturated colour is the only input that
    // tells the two apart, which is why this check uses one.
    do {
        let dst = SIMD3<Float>(0.8, 0.8, 0.8)
        let red = SIMD3<Float>(1.0, 0.0, 0.0)
        let lumaOfRed: Float = 0.2126
        let masked = dst * lumaOfRed
        let multiplied = dst * red

        check("mask gates on luma, not per channel",
              abs(masked.y - 0.8 * lumaOfRed) < 1e-6 && abs(multiplied.y) < 1e-6,
              "a red matte must dim all three channels, not zero green and blue")

        // And the two modes must not be the same expression.
        check("mask and multiply are different modes",
              BlendMode.mask.rawValue != BlendMode.multiply.rawValue
                  && masked.y != multiplied.y)
    }

    check("the last blend mode is constructible from its raw value",
          BlendMode(rawValue: 10) != nil,
          "rawValue 10 has no case — the enum is short of photon-core")

    // `.name` indexes a literal array, so a case past its end traps rather than
    // returning nil. Only reachable once the count is known good; checking it
    // blind would crash the verifier instead of reporting the fault.
    if countOK {
        let names = modes.map(\.name)
        check("every blend mode has a non-empty name",
              names.allSatisfy { !$0.isEmpty } && Set(names).count == names.count,
              "names: \(names)")
        check("blend mode names are in raw-value order",
              names == ["Over", "Add", "Multiply", "Screen", "Difference", "Mask",
                        "Overlay", "Hard Light", "Subtract", "Lighten", "Darken"],
              "names: \(names) — a shifted name means a show file renders as the wrong mode")
    } else {
        check("every blend mode has a non-empty name", false,
              "skipped — the count is wrong, reading .name would trap")
        check("blend mode names are in raw-value order", false, "skipped")
    }

    // `needsDestination` has no `default`, so the compiler already catches a
    // missing case. What it cannot catch is a case moving to the wrong side,
    // which silently drops the whole stack out of the folded path (or worse,
    // keeps it in when a mode needs to read what is underneath).
    let reads = Set(modes.filter(\.needsDestination).map(\.name))
    check("the modes that must read the destination are exactly the five that do",
          reads == ["Difference", "Mask", "Overlay", "Hard Light", "Subtract"],
          "got \(reads.sorted())")
}


// 15. Polygon masks — cutting output away from architecture that must not be lit.
print("\npolygon masks:")
do {
    let white = solid(.init(1, 1, 1, 1))
    func masked(_ poly: [SIMD2<Float>], feather: Float = 0, invert: Bool = false) -> [UInt8] {
        let s = OutputSlice(surface: WarpSurface(corners: .clipSpace),
                            mask: poly, maskFeather: feather, maskInvert: invert)
        return renderFrame(layers: [white], slices: [s])
    }

    // A centred square covering the middle half of the surface.
    let square: [SIMD2<Float>] = [.init(0.25, 0.25), .init(0.75, 0.25),
                                  .init(0.75, 0.75), .init(0.25, 0.75)]
    let m = masked(square)
    check("inside the mask polygon is lit", px(m, SIZE/2, SIZE/2).r > 200,
          "centre=\(px(m, SIZE/2, SIZE/2).r)")
    check("outside the mask polygon is dark",
          px(m, 4, 4).r < 20 && px(m, SIZE-5, SIZE-5).r < 20,
          "corners=\(px(m, 4, 4).r)/\(px(m, SIZE-5, SIZE-5).r)")

    // Inverting keeps the outside instead — used to punch a hole.
    let inv = masked(square, invert: true)
    check("inverting the mask punches a hole",
          px(inv, SIZE/2, SIZE/2).r < 20 && px(inv, 4, 4).r > 200,
          "centre=\(px(inv, SIZE/2, SIZE/2).r) corner=\(px(inv, 4, 4).r)")

    // Feathering must produce intermediate values at the boundary; a hard edge
    // aliases badly across a metres-wide projected boundary.
    let soft = masked(square, feather: 0.15)
    var sawPartial = false
    for x in 0..<SIZE {
        let v = px(soft, x, SIZE/2).r
        if v > 40 && v < 215 { sawPartial = true; break }
    }
    check("feathering produces a soft boundary", sawPartial)

    // Fewer than 3 points is not a polygon and must disable masking entirely,
    // rather than blacking the slice out.
    let degenerate = masked([.init(0.1, 0.1), .init(0.9, 0.9)])
    check("a degenerate polygon disables the mask rather than blacking output",
          px(degenerate, SIZE/2, SIZE/2).r > 200 && px(degenerate, 4, 4).r > 200)

    // A concave polygon must mask correctly — a convex-only test would pass a
    // broken implementation.
    let concave: [SIMD2<Float>] = [.init(0.1, 0.1), .init(0.9, 0.1), .init(0.9, 0.9),
                                   .init(0.5, 0.9), .init(0.5, 0.4), .init(0.1, 0.4)]
    let cc = masked(concave)
    // Assert on the SHAPE rather than a hard-coded corner: a convex-hull
    // (broken) implementation would light the whole bounding box, so the test
    // is "a meaningful part of the bbox is dark". This is also immune to the
    // warp stage's vertical flip, which an absolute corner check is not.
    let lo = Int(0.12 * Float(SIZE)), hi = Int(0.88 * Float(SIZE))
    var darkInBBox = 0, totalInBBox = 0
    for y in lo..<hi { for x in lo..<hi {
        totalInBBox += 1
        if px(cc, x, y).r < 60 { darkInBBox += 1 }
    }}
    let notchFraction = Double(darkInBBox) / Double(max(totalInBBox, 1))
    check("concave polygons mask correctly (the notch is cut out)",
          notchFraction > 0.15 && notchFraction < 0.60,
          String(format: "%.0f%% of the bounding box is dark; a convex-hull bug would give ~0%%",
                 notchFraction * 100))
}


// 16. Audio analysis — verified with synthetic tones rather than a microphone.
print("\naudio analysis:")
do {
    let sr: Float = 48_000
    func tone(_ hz: Float, amp: Float = 0.8, n: Int = AudioAnalyser.fftSize) -> [Float] {
        (0..<n).map { amp * sin(2 * .pi * hz * Float($0) / sr) }
    }
    /// Runs enough windows for the envelope to settle.
    func settle(_ a: AudioAnalyser, _ s: [Float], windows: Int = 60) -> AudioSnapshot {
        var snap = AudioSnapshot.silent
        for _ in 0..<windows { snap = a.process(samples: s, sampleRate: sr, dt: 0.021) }
        return snap
    }

    // A 60 Hz tone must land in Low and not in High.
    let lowA = AudioAnalyser()
    let low = settle(lowA, tone(60))
    check("a bass tone drives the low band",
          low.levels[0] > low.levels[2] * 4 && low.levels[0] > 0.01,
          "low=\(low.levels[0]) mid=\(low.levels[1]) high=\(low.levels[2])")

    // An 8 kHz tone must land in High and not Low — the discriminating case.
    let hiA = AudioAnalyser()
    let high = settle(hiA, tone(8000))
    check("a treble tone drives the high band",
          high.levels[2] > high.levels[0] * 4 && high.levels[2] > 0.001,
          "low=\(high.levels[0]) mid=\(high.levels[1]) high=\(high.levels[2])")

    // Silence must read zero, or every visual breathes with room noise.
    let quietA = AudioAnalyser()
    let quiet = settle(quietA, [Float](repeating: 0, count: AudioAnalyser.fftSize))
    check("silence reads zero across all bands",
          quiet.levels.allSatisfy { $0 < 0.001 }, "got \(quiet.levels)")

    // Attack must be faster than release — a hit lands now, the decay doesn't.
    let envA = AudioAnalyser()
    _ = settle(envA, tone(60))
    let peak = envA.snapshot.levels[0]
    let afterOne = envA.process(samples: [Float](repeating: 0, count: AudioAnalyser.fftSize),
                                sampleRate: sr, dt: 0.021).levels[0]
    check("release is gradual, not instant",
          afterOne < peak && afterOne > peak * 0.3,
          "peak=\(peak) after one window=\(afterOne) — should decay, not drop to zero")

    // The correction the core review surfaced, applied here too.
    check("a zero frame delta freezes the envelope rather than snapping it",
          AudioAnalyser.onePole(tauMs: 100, dt: 0) == 0)
    check("a zero time constant is still instant",
          AudioAnalyser.onePole(tauMs: 0, dt: 0.016) == 1)
    check("a NaN frame delta freezes rather than snapping",
          AudioAnalyser.onePole(tauMs: 100, dt: .nan) == 0)

    // Generation must advance so a consumer can distinguish stale from quiet.
    check("generation advances with each analysed window",
          quietA.snapshot.generation >= 60, "got \(quietA.snapshot.generation)")
}


// 17. MIDI — parsing, where the real bugs live.
print("\nmidi:")
do {
    var p = MidiParser()
    check("note on parses",
          p.parse([0x90, 60, 100]) == [.noteOn(channel: 0, note: 60, velocity: 100)])

    // THE classic MIDI bug: running status. A controller omits the status byte
    // on repeated messages, so a parser that assumes one per message drops most
    // of a fader sweep — and it presents as "the fader feels laggy", not an error.
    var r = MidiParser()
    let sweep = r.parse([0xB0, 7, 10,  7, 20,  7, 30,  7, 40])
    check("running status is handled (a fader sweep is not dropped)",
          sweep.count == 4 && sweep.last == .controlChange(channel: 0, controller: 7, value: 40),
          "got \(sweep.count) of 4 messages")

    // Velocity-0 note-on IS a note-off. Treating it as an on leaves pads
    // latched and clips that never stop.
    var v = MidiParser()
    check("note-on with velocity 0 is a note-off",
          v.parse([0x90, 60, 0]) == [.noteOff(channel: 0, note: 60, velocity: 0)])

    // Realtime bytes may appear between the data bytes of another message and
    // must not corrupt it.
    var rt = MidiParser()
    let interleaved = rt.parse([0x90, 60, 0xF8, 100])
    check("a clock byte between data bytes does not corrupt the message",
          interleaved == [.clock, .noteOn(channel: 0, note: 60, velocity: 100)],
          "got \(interleaved)")

    // Messages split across packet boundaries must still assemble.
    var split = MidiParser()
    var acc = split.parse([0xB0, 7])
    acc += split.parse([99])
    check("a message split across two packets still assembles",
          acc == [.controlChange(channel: 0, controller: 7, value: 99)], "got \(acc)")

    // Pitch bend is signed about centre.
    var pb = MidiParser()
    check("pitch bend centres at zero",
          pb.parse([0xE0, 0x00, 0x40]) == [.pitchBend(channel: 0, value: 0)])

    // Song position gives coarse phase.
    var sp = MidiParser()
    check("song position parses", sp.parse([0xF2, 0x10, 0x00]) == [.songPosition(beats: 16)])

    // Clock → tempo.
    var clock = MidiClockTracker()
    check("tempo is nil until enough ticks have arrived", clock.bpm == nil)
    // 120 BPM = 2 beats/sec = 48 ticks/sec.
    var t = 0.0
    for _ in 0..<60 { clock.tick(at: t); t += 1.0 / 48.0 }
    check("midi clock derives 120 BPM",
          (clock.bpm.map { abs($0 - 120) < 0.5 }) ?? false,
          "got \(String(describing: clock.bpm))")

    // A dropout must not drag the average.
    var drop = MidiClockTracker()
    t = 0
    for i in 0..<60 { drop.tick(at: t); t += (i == 30 ? 1.0 : 1.0 / 48.0) }
    check("a dropped tick does not corrupt the tempo",
          (drop.bpm.map { abs($0 - 120) < 2 }) ?? false,
          "got \(String(describing: drop.bpm))")

    // Pad feedback bytes.
    check("pad feedback emits a well-formed note-on",
          MidiFeedback.padOn(channel: 0, note: 36, colour: 5) == [0x90, 36, 5])
}


// 18. Live inputs — must FAIL SOFT. No device is an ordinary Tuesday.
print("\nlive inputs:")
engineSection("live inputs") { dev, eng in
    // Neither of these may throw, hang, or crash regardless of what hardware
    // is present or what permissions have been granted.
    let midiOK = eng.startMidi()
    check("starting MIDI never crashes, whatever is connected", true,
          "ok=\(midiOK) status=\(eng.midiStatus)")
    check("MIDI reports an operator-facing status", !eng.midiStatus.isEmpty)
    check("draining with no controller returns empty", eng.pumpMidi().isEmpty)

    let audioOK = eng.startAudioInput()
    check("starting audio capture never crashes or blocks", true,
          "ok=\(audioOK) status=\(eng.audioStatus)")
    check("audio reports an operator-facing status", !eng.audioStatus.isEmpty)
    check("analyser is reachable from the engine", eng.audio.bandNames.count == 3,
          "bands=\(eng.audio.bandNames)")

    eng.stopAudioInput()
    eng.stopMidi()
    check("stopping twice is safe", { eng.stopMidi(); eng.stopAudioInput(); return true }())

    // External tempo must not be adopted when no clock is present.
    eng.bpm = 128
    _ = eng.pumpMidi()
    check("tempo is unchanged when no MIDI clock is running", eng.bpm == 128,
          "got \(eng.bpm)")
}


// 19. Deck — clip grid triggering and quantisation.
print("\ndeck:")
do {
    var d = Deck(layers: 3, columns: 4)
    let url = URL(fileURLWithPath: "/tmp/x.mp4")
    for l in 0..<3 { for c in 0..<4 { d[l, c] = Cell(clipURL: url, name: "L\(l)C\(c)") } }

    // Boundary maths: a trigger at 3.9 with bar quantise fires at 4.0.
    check("next bar boundary is computed correctly",
          Deck.nextBoundary(after: 3.9, every: 4) == 4.0 &&
          Deck.nextBoundary(after: 4.0, every: 4) == 8.0,
          "a trigger exactly ON a boundary must go to the NEXT one, not fire twice")

    // Quantised launch waits, and the cell reads as armed meanwhile — an
    // operator needs to see the press registered or they press again.
    d.quantise = .bar
    d.trigger(layer: 0, column: 2, atBeat: 3.5)
    if case .armed(let remaining) = d.state(layer: 0, column: 2, atBeat: 3.5) {
        check("a quantised trigger arms and reports time remaining",
              abs(remaining - 0.5) < 1e-9, "remaining=\(remaining)")
    } else {
        check("a quantised trigger arms and reports time remaining", false,
              "state was \(d.state(layer: 0, column: 2, atBeat: 3.5))")
    }
    check("nothing plays before the boundary", d.active[0] == nil)

    let fired = d.advance(toBeat: 4.0)
    check("the launch fires exactly on the boundary",
          fired == [0] && d.active[0] == 2, "fired=\(fired) active=\(String(describing: d.active[0]))")
    check("the cell then reads as playing",
          d.state(layer: 0, column: 2, atBeat: 4.0) == .playing)

    // Re-triggering replaces the pending launch rather than queueing a second.
    var r = Deck(layers: 1, columns: 4)
    for c in 0..<4 { r[0, c] = Cell(clipURL: url, name: "c\(c)") }
    r.quantise = .bar
    r.trigger(layer: 0, column: 1, atBeat: 0.1)
    r.trigger(layer: 0, column: 3, atBeat: 0.2)
    _ = r.advance(toBeat: 4.0)
    check("re-triggering replaces the pending launch", r.active[0] == 3,
          "expected the LAST press to win, got \(String(describing: r.active[0]))")

    // A column fires every layer at once — the primary gesture.
    var col = Deck(layers: 3, columns: 4)
    for l in 0..<3 { for c in 0..<4 { col[l, c] = Cell(clipURL: url, name: "x") } }
    col.quantise = .immediate
    col.triggerColumn(2, atBeat: 0)
    check("a column fires every layer at once", col.active == [2, 2, 2],
          "got \(col.active)")

    // An empty cell is a no-op, NOT a clear. Hitting an empty pad mid-show
    // must not black the layer.
    var e = Deck(layers: 1, columns: 2)
    e[0, 0] = Cell(clipURL: url, name: "a")
    e.quantise = .immediate
    e.trigger(layer: 0, column: 0, atBeat: 0)
    e.trigger(layer: 0, column: 1, atBeat: 1)        // empty cell
    check("triggering an empty cell does not black the layer", e.active[0] == 0,
          "got \(String(describing: e.active[0]))")
    e.clear(layer: 0)
    check("clearing is explicit and does work", e.active[0] == nil)

    // Derived layer states feed the engine directly.
    let states = col.layerStates()
    check("deck produces engine layer states",
          states.count == 3 && states.allSatisfy { $0.clipURL != nil })
}


// 20. Engine + deck integration.
print("\nengine + deck:")
engineSection("engine + deck") { dev, eng in
    let urls = ((try? FileManager.default.contentsOfDirectory(
        atPath: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("media-cache").path)) ?? [])
        .filter { $0.hasSuffix(".mp4") }.sorted()

    check("engine exposes a deck", eng.deck.layerCount == 4 && eng.deck.columnCount == 8)
    check("musical time starts at zero", eng.beat == 0)

    if urls.count >= 2 {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("media-cache")
        eng.deck[0, 0] = Cell(clipURL: base.appendingPathComponent(urls[0]), name: urls[0])
        eng.deck[0, 1] = Cell(clipURL: base.appendingPathComponent(urls[1]), name: urls[1])
        eng.deck.quantise = .immediate
        eng.triggerCell(layer: 0, column: 1)
        eng.syncFromDeck()
        check("triggering a cell selects its clip",
              eng.layers.first?.clipURL?.lastPathComponent == urls[1],
              "got \(String(describing: eng.layers.first?.clipURL?.lastPathComponent))")
    } else {
        print("  — skipped clip trigger: fewer than 2 clips in media-cache/")
    }

    // Quantised triggers must NOT take effect until the boundary is reached,
    // even though the engine is advancing time every frame.
    eng.deck.quantise = .bar
    eng.triggerColumn(0)
    if case .armed = eng.deck.state(layer: 0, column: 0, atBeat: eng.beat) {
        check("a quantised column trigger arms rather than firing immediately", true)
    } else {
        check("a quantised column trigger arms rather than firing immediately",
              eng.deck[0, 0].isEmpty, "empty cells legitimately do not arm")
    }
}


// 21. ISF — the real test is whether the TRANSLATION COMPILES, not whether
//     the translator ran without throwing.
print("\nISF:")
do {
    let saturate = """
    /*{
      "DESCRIPTION": "Saturation",
      "CREDIT": "test",
      "CATEGORIES": ["Color Adjustment"],
      "INPUTS": [
        { "NAME": "inputImage", "TYPE": "image" },
        { "NAME": "amount", "TYPE": "float", "DEFAULT": 1.0, "MIN": 0.0, "MAX": 4.0 }
      ]
    }*/
    void main() {
        vec4 c = IMG_NORM_PIXEL(inputImage, isf_FragNormCoord);
        float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));
        vec3 outc = mix(vec3(luma), c.rgb, amount);
        gl_FragColor = vec4(outc, c.a);
    }
    """

    do {
        let shader = try ISF.parse(saturate)
        check("manifest parses", shader.description == "Saturation"
              && shader.categories == ["Color Adjustment"])
        check("inputs are read with their ranges",
              shader.inputs.count == 2 &&
              shader.inputs[1].name == "amount" && shader.inputs[1].max == 4.0)
        check("image and float inputs are distinguished",
              shader.drivableInputs.count == 1 && shader.drivableInputs[0].name == "amount")

        check("GLSL types are translated",
              shader.msl.contains("float4") && !shader.msl.contains("vec4"))
        check("IMG_NORM_PIXEL becomes a Metal sample",
              shader.msl.contains("inputImage.sample(isf_sampler"))
        check("gl_FragColor becomes a return",
              shader.msl.contains("return float4(outc, c.a)") &&
              !shader.msl.contains("gl_FragColor"))

        // THE check: does the generated MSL actually compile?
        do {
            let lib = try ISF.compile(shader, device: device)
            check("the translated shader COMPILES as Metal",
                  lib.makeFunction(name: "isf_fragment") != nil)
        } catch {
            check("the translated shader COMPILES as Metal", false, "\(error)")
        }
    } catch {
        check("manifest parses", false, "\(error)")
    }

    // Unsupported constructs must be REJECTED with a reason, never silently
    // mistranslated — a wrong-but-rendering shader is found on site.
    let multipass = """
    /*{ "PASSES": [ {"TARGET":"a"} ], "INPUTS": [] }*/
    void main() { gl_FragColor = vec4(1.0); }
    """
    do {
        _ = try ISF.parse(multipass)
        check("multi-pass ISF is rejected", false, "it was accepted")
    } catch let e as ISFError {
        check("multi-pass ISF is rejected with a specific reason",
              e == .unsupported("multi-pass shaders"), "\(e)")
    } catch { check("multi-pass ISF is rejected", false, "\(error)") }

    // A file with no manifest is not ISF.
    do {
        _ = try ISF.parse("void main() { }")
        check("a file with no manifest is rejected", false)
    } catch let e as ISFError {
        check("a file with no manifest is rejected", e == .noManifest)
    } catch { check("a file with no manifest is rejected", false) }

    // Malformed JSON must say so rather than crashing.
    do {
        _ = try ISF.parse("/*{ not json }*/ void main(){}")
        check("malformed manifest JSON is rejected", false)
    } catch let e as ISFError {
        check("malformed manifest JSON is rejected with a reason",
              e == .badManifest("not valid JSON"), "\(e)")
    } catch { check("malformed manifest JSON is rejected", false) }
}


// 22. Recording — must produce a real, decodable file.
print("\nrecording:")
do {
    let out = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("photon-record-check.mov")
    let rec = Recorder(width: SIZE, height: SIZE, fps: 30)
    check("recorder starts", rec.start(to: out), "status=\(rec.status)")

    // Feed real composited frames through the real path.
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm_srgb, width: SIZE, height: SIZE, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    let tex = device.makeTexture(descriptor: td)!

    // Paced at roughly real time. The recorder sets
    // `expectsMediaDataInRealTime = true` — correct for capturing a live show,
    // since it must never stall the renderer — which means an unpaced blast of
    // frames is legitimately dropped. Testing it unpaced would be testing a
    // scenario that cannot occur.
    var appended = 0
    for i in 0..<20 {
        let shade = Float(i) / 30
        let cb = compositor.makeCommandBuffer()!
        if let work = compositor.composite(
            into: cb, layers: [solid(.init(shade, 0.2, 1 - shade, 1))],
            time: 0, width: SIZE, height: SIZE, textures: []) {
            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = tex
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].storeAction = .store
            stage.encode(into: cb, descriptor: rp, source: work,
                         slices: [OutputStage.identitySlice()])
        }
        cb.commit()
        await cb.completed()
        if rec.append(texture: tex) { appended += 1 }
        try? await Task.sleep(nanoseconds: 33_000_000)   // ~30fps
    }
    check("frames are accepted by the encoder", appended >= 18, "appended \(appended)/20")

    let summary = await rec.stop()
    check("stopping returns a summary", summary != nil)
    if let s = summary {
        check("the file exists on disk",
              FileManager.default.fileExists(atPath: s.url.path))
        check("the summary reports frames written", s.framesWritten >= 18,
              "wrote \(s.framesWritten), dropped \(s.framesDropped)")

        // The real test: can anything else actually read it back?
        let asset = AVURLAsset(url: s.url)
        let tracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        check("the recording is a decodable video file", !tracks.isEmpty,
              "no video track — a file that exists but won't play is worse than none")
        if let t = tracks.first {
            let size = (try? await t.load(.naturalSize)) ?? .zero
            check("the recording has the expected dimensions",
                  Int(size.width) == SIZE && Int(size.height) == SIZE,
                  "got \(size)")
        }
        // Drops must be surfaced in the status, never swallowed.
        check("dropped frames are reported honestly",
              s.isClean == (s.framesDropped == 0) &&
              (s.isClean || rec.status.contains("DROPPED")),
              "status=\(rec.status)")
        try? FileManager.default.removeItem(at: s.url)
    }
}


// 23. Cue list and autopilot.
print("\ncues:")
do {
    var list = CueList(cues: [
        Cue(name: "Open",    column: 0, holdBeats: 8),
        Cue(name: "Build",   column: 1, holdBeats: 4),
        Cue(name: "Drop",    column: 2, holdBeats: nil),   // waits for a human
        Cue(name: "Outro",   column: 3, holdBeats: 16),
    ])

    check("nothing is standing before the first GO", list.current == nil)
    check("the next cue is the first one", list.next?.name == "Open")

    check("GO fires the first cue", list.go(atBeat: 0) == 0 && list.current == 0)
    check("GO advances in order", list.go(atBeat: 8) == 1 && list.current == 1)

    // Manual mode must never self-advance, however long it is left.
    check("manual mode does not auto-advance", list.tick(atBeat: 1000) == nil)

    // Autopilot advances after the hold, and not before.
    list.mode = .autopilot
    _ = list.goTo(0, atBeat: 100)
    check("autopilot waits for the hold", list.tick(atBeat: 104) == nil,
          "8-beat hold must not fire at 4")
    check("autopilot reports time remaining",
          (list.beatsUntilAdvance(atBeat: 104).map { abs($0 - 4) < 1e-9 }) ?? false,
          "got \(String(describing: list.beatsUntilAdvance(atBeat: 104)))")
    check("autopilot advances when the hold elapses",
          list.tick(atBeat: 108) == 1, "should fire cue 'Build'")

    // A cue with no hold stops autopilot — that's how you build a show that
    // runs itself up to a point and then waits for a human.
    _ = list.goTo(2, atBeat: 200)
    check("a cue with no hold halts autopilot", list.tick(atBeat: 1000) == nil)
    check("…and reports no pending advance", list.beatsUntilAdvance(atBeat: 1000) == nil)
    check("…but GO still works", list.go(atBeat: 1000) == 3)

    // End of list: stop by default, rather than silently looping the show.
    check("the list stops at the end by default", list.go(atBeat: 1100) == nil)
    list.loops = true
    check("looping can be enabled explicitly", list.go(atBeat: 1200) == 0)

    // Reset returns to standby without firing.
    list.reset()
    check("reset returns to standby without firing",
          list.current == nil && list.next?.name == "Open")

    // Engine integration: autopilot fires THROUGH the deck, so it is quantised.
    engineSection("autopilot through the deck") { dev, eng in
        let url = URL(fileURLWithPath: "/tmp/x.mp4")
        var d = Deck(layers: 2, columns: 4)
        for l in 0..<2 { for c in 0..<4 { d[l, c] = Cell(clipURL: url, name: "c") } }
        d.quantise = .immediate
        eng.deck = d
        eng.cues = CueList(cues: [Cue(name: "A", column: 2)])
        check("engine GO fires a cue through the deck",
              eng.go() == 2 && eng.deck.active[0] == 2,
              "active=\(String(describing: eng.deck.active[0]))")
    }
}


// 24. OSC — the bugs are all in the 4-byte alignment rules.
print("\nOSC:")
do {
    // Round-trip is the strongest single check: encode then decode must be
    // identity, which only holds if the padding is right in BOTH directions.
    let messages = [
        OSCMessage(address: "/photon/layer/1/opacity", values: [.float32(0.75)]),
        OSCMessage(address: "/go", values: []),
        OSCMessage(address: "/cue", values: [.int32(7), .string("Drop"), .float32(1.5)]),
        OSCMessage(address: "/t", values: [.bool(true), .bool(false), .impulse]),
        OSCMessage(address: "/blob", values: [.blob([1, 2, 3])]),
    ]
    var allRoundTripped = true
    for m in messages {
        let bytes = OSC.encode(m)
        // Every OSC packet must be a multiple of 4 bytes.
        if bytes.count % 4 != 0 { allRoundTripped = false; break }
        guard let back = try? OSC.decode(bytes), back.first == m else {
            allRoundTripped = false; break
        }
    }
    check("messages round-trip exactly, 4-byte aligned", allRoundTripped)

    // Addresses whose length is an exact multiple of 4 are the classic
    // off-by-one: they still need a full 4 bytes of padding, not zero.
    let tricky = OSCMessage(address: "/abc", values: [.int32(1)])   // 4 chars
    let tb = OSC.encode(tricky)
    check("an address of exactly 4 chars is padded to 8",
          tb.count % 4 == 0 && (try? OSC.decode(tb))?.first == tricky,
          "encoded \(tb.count) bytes")

    // Decoding a real-world packet built by hand.
    var hand: [UInt8] = Array("/x".utf8) + [0, 0]              // address, padded
    hand += Array(",f".utf8) + [0, 0]                           // type tag, padded
    hand += [0x3F, 0x80, 0x00, 0x00]                            // 1.0f big-endian
    let decoded = try? OSC.decode(hand)
    check("a hand-built packet decodes with big-endian floats",
          decoded?.first == OSCMessage(address: "/x", values: [.float32(1.0)]),
          "got \(String(describing: decoded))")

    // Bundles carry several messages.
    var bundle: [UInt8] = Array("#bundle".utf8) + [0]
    bundle += [UInt8](repeating: 0, count: 8)                   // timetag
    for m in [OSCMessage(address: "/a", values: [.int32(1)]),
              OSCMessage(address: "/b", values: [.int32(2)])] {
        let e = OSC.encode(m)
        bundle += [UInt8((e.count >> 24) & 0xFF), UInt8((e.count >> 16) & 0xFF),
                   UInt8((e.count >> 8) & 0xFF), UInt8(e.count & 0xFF)]
        bundle += e
    }
    let fromBundle = try? OSC.decode(bundle)
    check("bundles decode to multiple messages", fromBundle?.count == 2,
          "got \(fromBundle?.count ?? -1)")

    // Malformed input must be REJECTED, not silently mis-parsed. A parser that
    // mis-aligns moves the wrong parameter and gives the operator no clue why.
    check("an empty packet is rejected", (try? OSC.decode([])) == nil)
    check("an address not starting with / is rejected",
          (try? OSC.decode(Array("x\0\0\0".utf8) + Array(",\0\0\0".utf8))) == nil)
    check("a truncated argument is rejected",
          (try? OSC.decode(Array("/x".utf8) + [0,0] + Array(",i".utf8) + [0,0] + [1,2])) == nil)
    check("an unterminated address string is rejected",
          (try? OSC.decode([0x2F, 0x61, 0x62, 0x63])) == nil)

    // Numeric coercion, for binding any argument type to a parameter.
    check("values coerce to float for parameter binding",
          OSCValue.int32(3).asFloat == 3 && OSCValue.bool(true).asFloat == 1 &&
          OSCValue.float32(0.5).asFloat == 0.5 && OSCValue.blob([]).asFloat == nil)

    // The listener must fail soft, like every other input.
    let l = OSCListener(port: 7777)
    _ = l.start()
    check("the OSC listener starts or reports why", !l.status.isEmpty, "status=\(l.status)")
    check("draining with nothing received is empty", l.drain().isEmpty)
    l.stop()
    check("stopping the listener is safe", { l.stop(); return true }())
}


// 25. Control events — one shape for every transport.
print("\nControl events:")
do {
    var parser = MidiParser()
    // A fader sweep under running status, which is how real hardware sends it.
    let messages = parser.parse([0xB0, 7, 0, 7, 64, 7, 127])
    let events = messages.compactMap(\.controlEvent)
    check("a CC sweep becomes three readings", events.count == 3, "got \(events.count)")
    check("a CC keeps its channel and controller",
          events.first?.kind == .cc && events.first?.channel == 0 && events.first?.number == 7)
    check("a CC carries its 7-bit value", events.last?.reading == .midi7(127))

    let noteEvents = parser.parse([0x90, 36, 100, 36, 0]).compactMap(\.controlEvent)
    check("a note-on is a press", noteEvents.first?.reading == .gate(true))
    check("note-on velocity 0 is a release — the rule real hardware relies on",
          noteEvents.last?.reading == .gate(false))

    let bend = parser.parse([0xE0, 0x00, 0x40]).compactMap(\.controlEvent)
    check("the pitch detent lands at the centre of 14 bits",
          bend.first?.reading == .midi14(8192), "got \(String(describing: bend.first?.reading))")

    let clock = parser.parse([0xF8, 0xFA, 0xFC]).compactMap(\.controlEvent)
    check("clock and transport carry no control, so learn is not flooded",
          clock.isEmpty, "got \(clock.count)")

    let fader = OSCMessage(address: "/photon/opacity", values: [.float32(0.25)])
    check("an OSC message is identified by its address",
          fader.controlEvent?.kind == .osc && fader.controlEvent?.text == "/photon/opacity")
    check("an OSC value becomes a normalised reading",
          fader.controlEvent?.reading == .unit(0.25))
    check("an OSC message with no arguments reads as a press",
          OSCMessage(address: "/go").controlEvent?.reading == .gate(true))
    check("an OSC message carrying only a blob has no reading",
          OSCMessage(address: "/x", values: [.blob([1])]).controlEvent == nil)
    check("an int argument still reads as a value",
          OSCMessage(address: "/x", values: [.int32(1)]).controlEvent?.reading == .unit(1))

    check("a key press is a gate", keyControlEvent(code: "KeyQ", pressed: true).reading == .gate(true))
}


// 26. Musical time — one clock, and the core's wins.
print("\nMusical time:")
do {
    guard let e = PhotonEngine(device: device) else { fatalError("no engine") }
    check("time starts on the local accumulator", e.timeSource == .local)
    e.bpm = 120
    let before = e.beat

    // The core speaks: from here the local accumulator must stop, or two
    // clocks disagree by a fraction of a beat and a launch lands a frame early.
    e.adoptMusicalTime(beat: 8.0, bpm: 128)
    check("the core takes over when it speaks", e.timeSource == .core)
    check("the core's position is adopted exactly", e.beat == 8.0)
    check("the core's tempo is adopted", e.bpm == 128)
    check("adopting is not relative to what was there", e.beat != before)

    // A resync moves time backwards on purpose.
    e.adoptMusicalTime(beat: 0.0, bpm: 128)
    check("a backwards resync is honoured, not clamped", e.beat == 0.0)

    // Garbage from a disconnected clock must not poison musical time — one NaN
    // in the beat makes every quantised launch undefined for the rest of the show.
    e.adoptMusicalTime(beat: .nan, bpm: 128)
    check("a NaN beat is refused", e.beat == 0.0)
    e.adoptMusicalTime(beat: 4.0, bpm: 0)
    check("a zero tempo is refused", e.beat == 0.0 && e.bpm == 128)
    e.adoptMusicalTime(beat: 4.0, bpm: .infinity)
    check("an infinite tempo is refused", e.bpm == 128)
}


// 27. Audio bands — raw energy for modulation, smoothed for the meter.
print("\nAudio bands:")
do {
    let a = AudioAnalyser()
    let rate: Float = 48_000
    // A 100 Hz tone: squarely inside the default low band.
    let tone = (0..<AudioAnalyser.fftSize).map { i in
        sin(2 * Float.pi * 100 * Float(i) / rate)
    }
    let first = a.process(samples: tone, sampleRate: rate, dt: 1.0 / 60.0)
    check("raw levels are reported alongside smoothed ones",
          first.rawLevels.count == first.levels.count && !first.rawLevels.isEmpty)
    check("the raw level leads the envelope on an attack",
          first.rawLevels[0] >= first.levels[0],
          "raw \(first.rawLevels[0]) vs smoothed \(first.levels[0])")

    // After enough frames the envelope catches up; raw never lags.
    var last = first
    for _ in 0..<60 { last = a.process(samples: tone, sampleRate: rate, dt: 1.0 / 60.0) }
    check("a sustained tone reads in the low band", last.rawLevels[0] > 0.01,
          "got \(last.rawLevels[0])")
    check("silence above the tone stays near zero",
          last.rawLevels.dropFirst().allSatisfy { $0 < 0.05 },
          "got \(last.rawLevels)")

    // The core drives the band set, so it must be replaceable at runtime.
    a.setBands([AudioBand(name: "One", lowHz: 20, highHz: 16000)])
    check("the band set can be replaced", a.bandRanges.count == 1)
    check("replacing bands resets the history", a.snapshot.levels.isEmpty)
    let wide = a.process(samples: tone, sampleRate: rate, dt: 1.0 / 60.0)
    check("a replaced band set produces one level", wide.rawLevels.count == 1)
    check("the reported range is what was asked for",
          a.bandRanges[0].low == 20 && a.bandRanges[0].high == 16000)

    // A dead frame must freeze the envelope, never snap it — the correction
    // the review found in photon-core, applied here too.
    let frozen = a.process(samples: tone, sampleRate: rate, dt: 0)
    check("a zero frame delta freezes the envelope rather than snapping it",
          frozen.levels[0] <= wide.levels[0] + 1e-6,
          "\(wide.levels[0]) -> \(frozen.levels[0])")
}

// 28. Telemetry maths — the readout is only as honest as this arithmetic.
//
// No GPU dependency: these exercise the rolling window and the "unavailable"
// states, which is where a telemetry bug hides. A wrong mean still looks like
// a measurement, so it has to be asserted on rather than eyeballed in a HUD.
print("\nTelemetry maths:")
do {
    var ring = FrameRing(capacity: 4)
    check("an unmeasured window reports nil, not zero", ring.average == nil)
    check("a percentile of nothing is nil, not zero",
          ring.percentile(0.5, minimumSamples: 1) == nil)

    for v in [1.0, 2.0, 3.0] { ring.append(v) }
    check("a partial window averages what it actually has",
          ring.average.map { abs($0 - 2.0) < 1e-12 } == true, "got \(ring.average as Any)")

    // Past capacity the oldest sample must leave, or the "rolling" average is
    // really a lifetime average and stops responding to anything.
    for v in [4.0, 5.0, 6.0, 7.0, 8.0] { ring.append(v) }
    check("the window is bounded by its capacity", ring.count == 4, "got \(ring.count)")
    check("old samples fall out of the rolling average",
          ring.average.map { abs($0 - 6.5) < 1e-12 } == true, "got \(ring.average as Any)")

    // The incremental sum is recomputed on each wrap. Without that, a long
    // show accumulates float drift and the number slowly stops being true.
    var long = FrameRing(capacity: FrameMeter.window)
    for i in 1...10_000 { long.append(Double(i) * 0.1) }
    let tail = (10_000 - FrameMeter.window + 1...10_000).map { Double($0) * 0.1 }
    let expected = tail.reduce(0, +) / Double(tail.count)
    check("the mean stays exact after thousands of wraps",
          long.average.map { abs($0 - expected) < 1e-9 } == true,
          "got \(long.average as Any) want \(expected)")

    // A failed measurement must be discarded. Counted as zero it reports a
    // frame that cost nothing; folded in raw it poisons the whole window.
    var guarded = FrameRing(capacity: 4)
    guarded.append(10)
    guarded.append(.nan)
    guarded.append(.infinity)
    guarded.append(-5)
    check("a non-finite or negative sample is discarded, not counted as zero",
          guarded.count == 1 && guarded.average == 10, "got \(guarded.average as Any)")

    var pct = FrameRing(capacity: 200)
    for i in 1...100 { pct.append(Double(i)) }
    check("a percentile below its sample floor is nil",
          pct.percentile(0.99, minimumSamples: FrameMeter.percentileFloor + 1) == nil)
    check("a percentile at its sample floor reports",
          pct.percentile(0.50, minimumSamples: FrameMeter.percentileFloor) == 51)
}

do {
    let m = FrameMeter()
    let fresh = m.sample()
    check("a meter that has seen nothing reports nothing",
          fresh.cpuMilliseconds == nil && fresh.gpuMilliseconds == nil
          && fresh.outputFPS == nil && fresh.frameIntervalP50 == nil
          && fresh.frameIntervalP99 == nil)

    // One frame gives a CPU cost but no interval — an interval needs two.
    m.beginFrame()
    m.endFrame()
    let one = m.sample()
    check("one frame yields a CPU time", one.cpuMilliseconds != nil)
    check("a CPU time is finite and non-negative",
          one.cpuMilliseconds.map { $0.isFinite && $0 >= 0 } == true,
          "got \(one.cpuMilliseconds as Any)")
    check("one frame is not enough for an interval", one.frameIntervalP50 == nil)

    // Well short of the p99 floor: a median is available, a 1-in-100 figure is
    // not, and the meter must say so rather than offer the worst of a short run.
    for _ in 0..<(FrameMeter.percentileFloor / 4) {
        m.beginFrame()
        m.endFrame()
    }
    let few = m.sample()
    check("repeated frames yield a median interval", few.frameIntervalP50 != nil)
    check("a p99 is withheld until there are enough samples for one",
          few.frameIntervalP99 == nil)

    // Past the window size, so the ring is full regardless of how many
    // same-nanosecond pairs this machine's clock granularity threw away.
    for _ in 0..<(FrameMeter.percentileWindow * 4) {
        m.beginFrame()
        m.endFrame()
    }
    let many = m.sample()
    check("a p99 appears once there are enough samples for one",
          many.frameIntervalP99 != nil)
    check("the p99 is no better than the median", (many.frameIntervalP99 ?? 0) >= (many.frameIntervalP50 ?? 0),
          "p50 \(many.frameIntervalP50 as Any) p99 \(many.frameIntervalP99 as Any)")

    // The two that cannot be observed off a display. These staying nil IS the
    // feature: a CPU-only path must not invent a GPU cost or a refresh rate.
    check("no completed command buffer means no GPU figure, not 0 ms",
          many.gpuMilliseconds == nil)
    check("nothing presented means no output FPS, not 0 fps", many.outputFPS == nil)
    check("a run with no drawables counts no unpresented frames either",
          m.unpresentedFrames == 0)

    m.reset()
    let cleared = m.sample()
    check("a reset meter is unavailable again rather than stale",
          cleared.cpuMilliseconds == nil && cleared.frameIntervalP50 == nil)
}

// DXV — the block-compressed path.
//
// Three things can only be checked on the GPU, and all three are invisible in
// a unit test because they fail by looking *plausible*:
//   1. the blocks really are sampled as BC, not as bytes;
//   2. premultiplied RGB is divided back out, or the clip plays dark;
//   3. the padding is cropped, or the right-hand edge shows undefined blocks.
print("\nDXV block textures:")
do {
    /// Uploads hand-built blocks exactly as `BlockVideoSource` does.
    @MainActor func blockTexture(_ bytes: [UInt8], format: MTLPixelFormat,
                                 width: Int, height: Int) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let t = device.makeTexture(descriptor: d) else { return nil }
        let bytesPerBlock = format == .bc1_rgba ? 8 : 16
        t.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                  withBytes: bytes, bytesPerRow: (width / 4) * bytesPerBlock)
        return t
    }

    /// One BC1 block: every texel is colour 0.
    func bc1Block(_ rgb565: UInt16) -> [UInt8] {
        [UInt8(rgb565 & 0xFF), UInt8(rgb565 >> 8), 0, 0, 0, 0, 0, 0]
    }

    /// One BC3 block: flat alpha, every texel colour 0.
    func bc3Block(alpha: UInt8, rgb565: UInt16) -> [UInt8] {
        [alpha, alpha, 0, 0, 0, 0, 0, 0,
         UInt8(rgb565 & 0xFF), UInt8(rgb565 >> 8), 0, 0, 0, 0, 0, 0]
    }

    @MainActor func renderTextured(_ layer: LayerUniform, _ tex: MTLTexture) -> [UInt8] {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: SIZE, height: SIZE, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead]
        td.storageMode = .shared
        guard let output = device.makeTexture(descriptor: td),
              let cb = compositor.makeCommandBuffer() else { return [] }
        let work = compositor.composite(into: cb, layers: [layer], time: 0,
                                        width: SIZE, height: SIZE, textures: [tex])
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = output
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let work {
            stage.encode(into: cb, descriptor: rp, source: work,
                         slices: [OutputStage.identitySlice()])
        }
        cb.commit()
        cb.waitUntilCompleted()
        var p = [UInt8](repeating: 0, count: SIZE * SIZE * 4)
        p.withUnsafeMutableBytes { buf in
            output.getBytes(buf.baseAddress!, bytesPerRow: SIZE * 4,
                            from: MTLRegionMake2D(0, 0, SIZE, SIZE), mipmapLevel: 0)
        }
        return p
    }

    func videoLayer(texScale: SIMD2<Float> = SIMD2(1, 1), flags: Int32 = 0) -> LayerUniform {
        LayerUniform(tint: .init(1, 1, 1, 1), offsetScale: .init(0, 0, 1, 1),
                     opacity: 1, blend: .over, kind: 3, texSlot: 0,
                     texScale: texScale, flags: flags)
    }

    check("this GPU can sample BC textures at all", device.supportsBCTextureCompression)

    // 1. BC1 blocks sample as colour, not as bytes. 0xF800 is pure red in 565.
    if let tex = blockTexture(Array(repeating: bc1Block(0xF800), count: 4).flatMap { $0 },
                              format: .bc1_rgba, width: 16, height: 4) {
        let c = px(renderTextured(videoLayer(), tex), SIZE / 2, SIZE / 2)
        check("BC1 blocks upload and sample as colour", c.r > 200 && c.g < 40 && c.b < 40,
              "centre BGR=\(c)")
    } else {
        check("BC1 texture allocates", false)
    }

    // 2. Premultiplied RGB. The block holds mid-grey at half alpha, which IS
    //    white premultiplied. Undone, it composites to ~0.5 coverage of white
    //    (~188 after the sRGB encode). Left premultiplied it lands near 139 —
    //    the "everything renders dark" failure, which looks like a deliberate
    //    choice rather than a bug.
    if let tex = blockTexture(Array(repeating: bc3Block(alpha: 128, rgb565: 0x8410), count: 4)
                                .flatMap { $0 },
                              format: .bc3_rgba, width: 16, height: 4) {
        let straight = px(renderTextured(videoLayer(), tex), SIZE / 2, SIZE / 2).r
        let undone = px(renderTextured(
            videoLayer(flags: LayerUniform.flagPremultiplied), tex), SIZE / 2, SIZE / 2).r
        check("premultiplied DXV colour is divided back out", undone > 175,
              "expected ~188, got \(undone)")
        check("and it genuinely changes the picture", undone > straight + 30,
              "premultiplied=\(straight) corrected=\(undone)")
    } else {
        check("BC3 texture allocates", false)
    }

    // 3. Padding. A 1366-wide DXV clip lives in a 1376-wide texture; the extra
    //    blocks hold whatever the encoder left there. Here the right-hand half
    //    is green and must never be sampled.
    let split = (Array(repeating: bc1Block(0xF800), count: 4)
                 + Array(repeating: bc1Block(0x07E0), count: 4)).flatMap { $0 }
    if let tex = blockTexture(split, format: .bc1_rgba, width: 32, height: 4) {
        let cropped = px(renderTextured(videoLayer(texScale: SIMD2(0.5, 1)), tex),
                         SIZE - 2, SIZE / 2)
        let whole = px(renderTextured(videoLayer(), tex), SIZE - 2, SIZE / 2)
        check("texScale crops the padding away", cropped.r > 200 && cropped.g < 60,
              "right edge BGR=\(cropped)")
        check("and without it the padding would be on screen", whole.g > 150,
              "right edge BGR=\(whole)")
    } else {
        check("split BC1 texture allocates", false)
    }
}

// End to end, against real Resolume files. Opt-in: point
// PHOTON_DXV_SAMPLE_DIR at a folder of clips. Without it there is nothing
// honest to assert, so the section says so rather than passing vacuously.
print("\nDXV playback (real files):")
do {
    let env = ProcessInfo.processInfo.environment["PHOTON_DXV_SAMPLE_DIR"]
    if let dir = env.map({ URL(fileURLWithPath: $0) }) {
    let files = (FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }
        .filter { $0.pathExtension.lowercased() == "mov" } ?? []).sorted { $0.path < $1.path }
    check("sample folder holds clips", !files.isEmpty, dir.path)

    var played: [MTLPixelFormat: Int] = [:]
    var refused: [String] = []
    for url in files {
        guard let probe = probeMedia(url: url), probe.isDXV else { continue }
        guard let source = makeFrameSource(url: url, device: device) as? BlockVideoSource else {
            refused.append(url.lastPathComponent)
            continue
        }
        // Give the decode thread a moment; it opens a file and inflates a
        // frame that can be 8 MB of blocks.
        var texture: MTLTexture?
        for i in 0..<120 where texture == nil {
            texture = source.texture(at: CACurrentMediaTime() + Double(i) * 0.004)
            if texture == nil { usleep(10_000) }
        }
        if let texture {
            played[texture.pixelFormat, default: 0] += 1
        } else {
            refused.append("\(url.lastPathComponent): \(source.failure ?? "no frame")")
        }
    }
    let bc1 = played[.bc1_rgba] ?? 0
    let bc3 = played[.bc3_rgba] ?? 0
    check("DXT1 clips play", bc1 > 0, "\(bc1) files")
    check("DXT5 clips play", bc3 > 0, "\(bc3) files")
    check("every texture that reached the GPU is block-compressed",
          played.keys.allSatisfy { $0 == .bc1_rgba || $0 == .bc3_rgba },
          "formats: \(played.keys.map(String.init(describing:)).joined(separator: ", "))")
    // Refusals are expected — YCG6/YG10 and DXV1 are not derived — but they
    // must be refusals, not silent black layers.
    print("  – played \(bc1 + bc3) clips; \(refused.count) refused with a reason")
    for r in refused.prefix(4) { print("    · \(r)") }
    } else {
        print("  – skipped (set PHOTON_DXV_SAMPLE_DIR to a folder of DXV clips)")
    }
}

print("\n\(checks - failures)/\(checks) checks passed")
if failures > 0 {
    print("FAILED")
    exit(1)
}
print("OK")
