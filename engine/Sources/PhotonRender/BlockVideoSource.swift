// DXV playback — the block-compressed path.
//
// ## The point of this file
//
// A DXV frame is a GPU texture that happens to have been run through an LZ
// pass. The frames are ALREADY BC1 or BC3 blocks. So the work is:
//
//     demux (AVFoundation)  ->  undo the LZ (photon-core, via the C ABI)
//                           ->  upload the blocks to a COMPRESSED texture
//
// and at no point does an RGBA pixel exist. FFmpeg's own DXV decoder does
// produce RGBA, and linking it would have been less code — but a 4K DXT5 frame
// is 8.3 MB of blocks and 33 MB of RGBA, so that choice costs 4x the upload
// bandwidth and 4x the texture memory, every frame, on every layer. The whole
// reason an operator's Resolume library is in DXV is to not pay that.
//
// ## Demux, not parse
//
// AVFoundation will happily *demux* a codec it cannot *decode*: an
// `AVAssetReaderTrackOutput` with `outputSettings: nil` hands back the DXV
// samples untouched, with their timestamps. So there is no hand-written MOV
// parser here and none in the core either — the same boundary the Windows
// shell will hold with libavformat.
//
// ## Threading
//
// DXV has no chunk table: one frame is one contiguous LZ stream and cannot be
// split across workers. Parallelism is across LAYERS, so each source owns one
// decode thread and one decoder, and shares nothing.
//
// Decoded frames land in a ring of textures. The ring is 4 deep against a
// queue bound of 2, so a texture is never rewritten while the GPU could still
// be reading it: at most one is on screen and at most two are queued behind it.

import AVFoundation
import Metal
import PhotonFFI
import simd

/// A looping DXV clip, decoded to BC blocks and uploaded compressed.
public final class BlockVideoSource: FrameSource, @unchecked Sendable {
    public let url: URL

    /// Why this source is not producing frames, if it is not. Surfaced rather
    /// than swallowed: a clip that silently stays black during a show is the
    /// worst possible failure mode.
    public private(set) var failure: String?

    public private(set) var repeatedFrames: Int = 0
    public private(set) var textureScale = SIMD2<Float>(1, 1)
    public private(set) var isPremultiplied = false

    /// Visible frame size. The texture may be larger — see `textureScale`.
    public let width: Int
    public let height: Int

    public var transport = ClipTransport() {
        didSet { lock.withLock { pendingRestart = true } }
    }
    public var bpm: Double = 120

    private let device: MTLDevice
    private let probe: MediaProbe
    private let duration: Double

    // Ring of destination textures. See the threading note above for why 4.
    private static let ringDepth = 4
    private static let queueBound = 2
    private var ring: [MTLTexture] = []
    private var ringCursor = 0

    private let lock = NSLock()
    private let slots = DispatchSemaphore(value: BlockVideoSource.queueBound)
    private var ready: [(pts: Double, texture: MTLTexture)] = []
    private var pendingRestart = false
    private var stopped = false
    private var paused = false
    private var thread: Thread?

    /// Clip-time position in seconds, advanced by the render thread.
    private var position: Double = 0
    private var lastHostTime: CFTimeInterval?
    private var held: MTLTexture?

    init?(probe: MediaProbe, url: URL, device: MTLDevice) {
        self.url = url
        self.device = device
        self.probe = probe
        self.width = probe.width
        self.height = probe.height
        self.duration = probe.duration > 0 ? probe.duration : 1
        guard probe.width > 0, probe.height > 0 else { return nil }

        // BC sampling is a hardware capability, not a Metal feature level we
        // can polyfill. If it is absent, say so once rather than uploading
        // blocks the GPU will read as noise.
        guard device.supportsBCTextureCompression else {
            print("[BlockVideoSource] \(url.lastPathComponent): this GPU cannot sample BC textures")
            return nil
        }
        start()
    }

    deinit {
        lock.withLock { stopped = true }
    }

    public func play() { lock.withLock { paused = false } }
    public func pause() { lock.withLock { paused = true } }

    // MARK: - Render thread

    public func texture(at hostTime: CFTimeInterval) -> MTLTexture? {
        advanceClock(to: hostTime)

        var picked: MTLTexture?
        lock.withLock {
            // Take the newest frame that is due, discarding everything older.
            // Dropping rather than queueing is correct for live visuals: a late
            // frame is worthless, and catching up by playing stale frames fast
            // looks like a stutter rather than like time passing.
            while let first = ready.first, first.pts <= position {
                picked = first.texture
                ready.removeFirst()
                slots.signal()
            }
        }
        if let picked {
            held = picked
            return picked
        }
        repeatedFrames += 1
        return nil
    }

    private func advanceClock(to hostTime: CFTimeInterval) {
        guard let last = lastHostTime else {
            lastHostTime = hostTime
            position = transport.trimIn * duration
            return
        }
        lastHostTime = hostTime
        if lock.withLock({ paused }) { return }

        let rate = min(max(transport.rate(bpm: bpm, clipSeconds: duration), 0.05), 16.0)
        let delta = (hostTime - last) * rate
        guard delta > 0, delta < 1 else { return } // a stall must not fast-forward

        let normalised = transport.advance(position: position / duration,
                                           by: delta / duration)
        let wrapped = normalised.position * duration < position
        position = normalised.position * duration

        switch transport.playthrough {
        case .once, .holdLast:
            // Hold the final frame. Blackout stays an explicit operator action,
            // never a side effect of a clip ending.
            if normalised.finished { lock.withLock { paused = true } }
        case .loop, .pingPong, .random:
            // AVAssetReader is strictly forward-only, so a wrap means the
            // reader has to be rebuilt. Ping-pong therefore restarts forward
            // rather than playing backwards — the same honest limitation
            // `VideoSource` documents, for the same reason.
            if wrapped { lock.withLock { pendingRestart = true } }
        }
    }

    // MARK: - Decode thread

    /// Starts the decode thread.
    ///
    /// The thread holds `self` **weakly, re-acquired once per iteration**, and
    /// never blocks indefinitely — the slot wait is timed. Together those two
    /// things are what let the source deallocate: a thread parked forever on a
    /// semaphore while holding a strong reference would keep every source a
    /// show ever launched alive, each with a 4-deep ring of 4K textures.
    private func start() {
        let t = Thread { [weak self] in
            guard let decoder = photon_dxv_decoder_create() else { return }
            defer { photon_dxv_decoder_destroy(decoder) }
            var reader: (AVAssetReader, AVAssetReaderTrackOutput)?
            while true {
                guard let strong = self else { break }
                if !strong.decodeStep(decoder: decoder, reader: &reader) { break }
            }
            reader?.0.cancelReading()
        }
        t.name = "photon.dxv.\(url.lastPathComponent)"
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    /// One pass of the decode loop. Returns `false` when the thread should end.
    private func decodeStep(decoder: OpaquePointer,
                            reader: inout (AVAssetReader, AVAssetReaderTrackOutput)?) -> Bool {
        if lock.withLock({ stopped }) { return false }
        let restart = lock.withLock { () -> Bool in
            let r = pendingRestart
            pendingRestart = false
            return r
        }
        if restart || reader == nil {
            reader?.0.cancelReading()
            flushQueued()
            reader = makeReader(from: startFraction())
        }
        guard let (r, output) = reader else { return false }

        // Timed, so the thread releases its strong reference regularly even
        // when nothing is consuming frames.
        guard slots.wait(timeout: .now() + 0.1) == .success else { return true }
        if lock.withLock({ stopped }) {
            slots.signal()
            return false
        }

        guard let sample = output.copyNextSampleBuffer() else {
            slots.signal()
            if r.status == .failed {
                report("read failed: \(r.error?.localizedDescription ?? "unknown")")
                return false
            }
            // End of the track. Rebuild for another pass; the render thread's
            // own wrap handling keeps the position honest.
            r.cancelReading()
            reader = makeReader(from: startFraction())
            return reader != nil
        }

        guard let texture = decode(sample, with: decoder) else {
            slots.signal()
            // A decode failure is terminal for the clip; a marker sample
            // buffer with no payload is not.
            return failure == nil
        }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        lock.withLock { ready.append((pts: pts, texture: texture)) }
        return true
    }

    /// Drops queued frames whose timestamps belong to the pass that just ended.
    ///
    /// Without this, a loop wrap leaves frames from the end of the clip sitting
    /// in front of frames from the start, and playback stalls until the
    /// position crawls back past them.
    private func flushQueued() {
        lock.withLock {
            for _ in ready { slots.signal() }
            ready.removeAll(keepingCapacity: true)
        }
    }

    private func startFraction() -> Double {
        switch transport.playthrough {
        case .random: return transport.trimIn + Double.random(in: 0...1) * transport.span
        default: return transport.trimIn
        }
    }

    private func makeReader(from fraction: Double) -> (AVAssetReader, AVAssetReaderTrackOutput)? {
        guard let reader = try? AVAssetReader(asset: probe.asset) else {
            report("could not open the container")
            return nil
        }
        // outputSettings nil = passthrough. AVFoundation demuxes a codec it
        // cannot decode, which is exactly what is wanted here.
        let output = AVAssetReaderTrackOutput(track: probe.track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            report("the container will not yield raw samples")
            return nil
        }
        reader.add(output)
        let start = max(0, min(fraction, 0.999)) * duration
        if start > 0 {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: .positiveInfinity)
        }
        guard reader.startReading() else {
            report("reader refused to start: \(reader.error?.localizedDescription ?? "unknown")")
            return nil
        }
        return (reader, output)
    }

    /// Decompresses one sample and uploads its blocks. Returns `nil` for the
    /// marker sample buffers AVFoundation emits, which carry no data.
    private func decode(_ sample: CMSampleBuffer,
                        with decoder: OpaquePointer) -> MTLTexture? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length > 0 else { return nil }

        let frame = pointer.withMemoryRebound(to: UInt8.self, capacity: length) {
            photon_dxv_decode(decoder, $0, UInt32(length), UInt32(width), UInt32(height))
        }
        guard frame.status == PHOTON_DXV_OK, let data = frame.data else {
            let why = String(cString: photon_dxv_last_error(decoder))
            // A format we cannot decode fails the clip and says which one.
            // Guessing at it would put plausible-looking wrong pixels on a wall
            // in front of an audience, which is strictly worse than a clip that
            // refuses to load.
            report(frame.status == PHOTON_DXV_NOT_DERIVED
                   ? "DXV variant not supported (\(why)) — re-encode as DXV3 DXT1/DXT5"
                   : "decode failed: \(why)")
            return nil
        }

        let pixelFormat: MTLPixelFormat
        if frame.format == PHOTON_TEX_BC1_RGB {
            pixelFormat = .bc1_rgba
        } else if frame.format == PHOTON_TEX_BC3_RGBA {
            pixelFormat = .bc3_rgba
        } else {
            report("texture format \(frame.format) has no Metal equivalent here")
            return nil
        }

        let tw = Int(frame.texture_width)
        let th = Int(frame.texture_height)
        guard let texture = ringTexture(format: pixelFormat, width: tw, height: th) else {
            report("could not allocate a \(tw)x\(th) \(pixelFormat) texture")
            return nil
        }

        // Straight from the LZ output into the compressed texture. One copy,
        // no expansion, no intermediate.
        let blocksWide = (tw + 3) / 4
        let bytesPerBlock = pixelFormat == .bc1_rgba ? 8 : 16
        texture.replace(
            region: MTLRegionMake2D(0, 0, tw, th),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: blocksWide * bytesPerBlock)

        textureScale = SIMD2(Float(width) / Float(tw), Float(height) / Float(th))
        isPremultiplied = frame.premultiplied != 0
        return texture
    }

    private func ringTexture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        if ring.first?.pixelFormat != format || ring.first?.width != width
            || ring.first?.height != height {
            ring.removeAll()
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            d.usage = .shaderRead
            // replaceRegion needs CPU-visible storage. Unified memory makes
            // `.shared` a true zero-copy upload; a discrete GPU has to stage.
            d.storageMode = device.hasUnifiedMemory ? .shared : .managed
            for _ in 0..<Self.ringDepth {
                guard let t = device.makeTexture(descriptor: d) else { return nil }
                ring.append(t)
            }
            ringCursor = 0
        }
        let t = ring[ringCursor]
        ringCursor = (ringCursor + 1) % ring.count
        return t
    }

    private func report(_ message: String) {
        guard failure == nil else { return }
        failure = message
        print("[BlockVideoSource] \(url.lastPathComponent): \(message)")
    }
}
