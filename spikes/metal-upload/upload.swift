// R0 #6 — HAP compressed-texture upload path spike.
//
// Question: what is the SUPPORTED path for getting BC blocks onto the GPU, and
// what does it cost? This exists because the originally-proposed zero-copy route
// (MTLBuffer.makeTexture on a BC format) does not work — Metal's buffer-backed
// texture API does not accept block-compressed formats.
//
// Two candidate paths, measured:
//   A. shared-storage texture + replaceRegion
//   B. shared MTLBuffer -> blit -> private texture
//
// Correctness is verified by sampling the uploaded texture into an rgba16Float
// linear target and reading the result back — not by assuming the upload worked.
//
// Isolated probe. Does not create the R1 application and does not touch macos/.

import Metal
import Foundation

let W = 1920, H = 1080
let BLOCKS_X = (W + 3) / 4, BLOCKS_Y = (H + 3) / 4
let BC1_BLOCK = 8
let FRAME_BYTES = BLOCKS_X * BLOCKS_Y * BC1_BLOCK   // 1,036,800 at 1080p
let ITERATIONS = 240                                 // ~4s of 60fps

guard let dev = MTLCreateSystemDefaultDevice(), let queue = dev.makeCommandQueue() else {
    print("no device"); exit(1)
}
guard dev.supportsBCTextureCompression else {
    print("FATAL: no BC support — the whole DXV/HAP plan needs this"); exit(1)
}

// ── A BC1 block encoding a known solid colour ───────────────────────────────
// BC1 block = colour0:u16 LE, colour1:u16 LE, then 4 bytes of 2-bit indices.
// colour0 == colour1 with all-zero indices means every pixel is colour0 — so
// the expected sampled value is exact and a wrong upload is unmistakable.
let RED565: UInt16 = 0xF800   // r=31, g=0, b=0
var block = [UInt8]()
block.append(UInt8(RED565 & 0xFF)); block.append(UInt8(RED565 >> 8))
block.append(UInt8(RED565 & 0xFF)); block.append(UInt8(RED565 >> 8))
block.append(contentsOf: [0, 0, 0, 0])
let frame = [[UInt8]](repeating: block, count: BLOCKS_X * BLOCKS_Y).flatMap { $0 }
precondition(frame.count == FRAME_BYTES)

let bytesPerRow = BLOCKS_X * BC1_BLOCK

func makeTexture(_ storage: MTLStorageMode) -> MTLTexture {
    let d = MTLTextureDescriptor()
    d.pixelFormat = .bc1_rgba
    d.width = W; d.height = H
    d.storageMode = storage
    d.usage = .shaderRead
    return dev.makeTexture(descriptor: d)!
}

// ── Correctness: sample the texture, render to linear, read back ────────────
let shaderSrc = """
#include <metal_stdlib>
using namespace metal;
vertex float4 v_main(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return float4(p * 2.0 - 1.0, 0.0, 1.0);
}
fragment float4 f_main(float4 pos [[position]], texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(filter::nearest);
    return tex.sample(s, float2(0.5, 0.5));
}
"""
let lib = try! dev.makeLibrary(source: shaderSrc, options: nil)
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "v_main")
pd.fragmentFunction = lib.makeFunction(name: "f_main")
pd.colorAttachments[0].pixelFormat = .rgba16Float
let pipeline = try! dev.makeRenderPipelineState(descriptor: pd)

func verify(_ tex: MTLTexture, label: String) {
    let td = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: 1, height: 1, mipmapped: false)
    td.usage = [.renderTarget, .shaderRead]
    td.storageMode = .shared
    let target = dev.makeTexture(descriptor: td)!

    let rp = MTLRenderPassDescriptor()
    rp.colorAttachments[0].texture = target
    rp.colorAttachments[0].loadAction = .clear
    rp.colorAttachments[0].storeAction = .store
    rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 1, blue: 0, alpha: 1)

    let cb = queue.makeCommandBuffer()!
    let enc = cb.makeRenderCommandEncoder(descriptor: rp)!
    enc.setRenderPipelineState(pipeline)
    enc.setFragmentTexture(tex, index: 0)
    enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()

    var px = [Float16](repeating: 0, count: 4)
    px.withUnsafeMutableBytes { buf in
        target.getBytes(buf.baseAddress!, bytesPerRow: 8,
                        from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0)
    }
    let r = Float(px[0]), g = Float(px[1]), b = Float(px[2])
    let ok = r > 0.95 && g < 0.05 && b < 0.05
    print(String(format: "  %@ decoded RGB = (%.3f, %.3f, %.3f)  %@",
                 label, r, g, b, ok ? "CORRECT" : "WRONG"))
    if !ok { print("    expected pure red from the BC1 block — upload or format is wrong") }
}

func bench(_ name: String, _ body: () -> Void) -> Double {
    body()  // warm
    let t0 = CFAbsoluteTimeGetCurrent()
    for _ in 0..<ITERATIONS { body() }
    let dt = (CFAbsoluteTimeGetCurrent() - t0) / Double(ITERATIONS)
    let gbps = Double(FRAME_BYTES) / dt / 1_000_000_000
    print(String(format: "  %@: %.3f ms/frame   %.2f GB/s   (%.0f layer-frames/s)",
                 name, dt * 1000, gbps, 1.0 / dt))
    return dt
}

print("=== R0 #6 — BC1 upload path spike ===")
print("device \(dev.name) · 1080p BC1 · \(FRAME_BYTES) B/frame · \(ITERATIONS) iterations\n")

// ── Path A: shared texture + replaceRegion ──────────────────────────────────
print("Path A — shared texture, replaceRegion")
let texA = makeTexture(.shared)
let dtA = bench("upload") {
    frame.withUnsafeBytes { raw in
        texA.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0,
                     withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
    }
}
verify(texA, label: "A")

// ── Path B: shared buffer -> blit -> private texture ────────────────────────
print("\nPath B — shared buffer, blit to private texture")
let buf = dev.makeBuffer(bytes: frame, length: FRAME_BYTES, options: .storageModeShared)!
let texB = makeTexture(.private)
let dtB = bench("upload+blit") {
    let cb = queue.makeCommandBuffer()!
    let blit = cb.makeBlitCommandEncoder()!
    blit.copy(from: buf, sourceOffset: 0,
              sourceBytesPerRow: bytesPerRow,
              sourceBytesPerImage: FRAME_BYTES,
              sourceSize: MTLSize(width: W, height: H, depth: 1),
              to: texB, destinationSlice: 0, destinationLevel: 0,
              destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
    blit.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
}
verify(texB, label: "B")

// ── Verdict ─────────────────────────────────────────────────────────────────
print("\n=== verdict ===")
let faster = dtA < dtB ? "A (replaceRegion)" : "B (buffer+blit)"
print(String(format: "faster: %@  (%.2fx)", faster, max(dtA, dtB) / min(dtA, dtB)))
// Tier A/B need 480 layer-frames/sec of upload headroom at 1080p.
let bestRate = 1.0 / min(dtA, dtB)
print(String(format: "480 layer-frames/s target: %@ (%.0f achievable)",
             bestRate >= 480 ? "MET" : "NOT MET", bestRate))
