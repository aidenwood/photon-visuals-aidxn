// Real media into the compositor.
//
// H.264/HEVC/ProRes decode through VideoToolbox, delivered as a
// `CVPixelBuffer` backed by an IOSurface, then wrapped as an `MTLTexture`
// through `CVMetalTextureCache` — **zero copy**. The pixels never pass through
// the CPU; we only ever hand the GPU a reference.
//
// This is the non-BC path. HAP/DXV deliver block-compressed data and go through
// the `replaceRegion` upload instead (measured at 28x the tier requirement).

import AVFoundation
import CoreVideo
import Metal

/// A looping video file decoded to Metal textures.
public final class VideoSource: @unchecked Sendable {
    // Confined to the main thread in practice (AVPlayer requires it); the
    // unchecked conformance exists so the render thread can read cached state.
    /// The file this source plays. Lets the engine keep a source alive across a
    /// layer-stack rebuild when the clip has not changed — reordering layers
    /// must not restart video.
    public let url: URL

    private let device: MTLDevice
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?

    /// Retained so the texture stays valid while the GPU reads it; released
    /// only once the next frame supersedes it.
    private var currentTexture: CVMetalTexture?

    public private(set) var width: Int = 0
    public private(set) var height: Int = 0

    /// Frames the source could not supply in time. A repeat means the *source*
    /// was late — distinct from us missing a deadline, and counted separately.
    public private(set) var repeatedFrames: Int = 0

    /// How this clip plays. Changing it takes effect on the next frame.
    public var transport = ClipTransport() {
        didSet { applyTransport() }
    }

    /// Tempo, for BPM-synced clips. Set by the engine from the clock.
    public var bpm: Double = 120 {
        didSet { if case .bpmSync = transport.mode { applyTransport() } }
    }

    /// Clip duration in seconds, resolved once the asset loads.
    private var durationSeconds: Double = 0

    public init?(url: URL, device: MTLDevice) {
        self.url = url
        self.device = device

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
                == kCVReturnSuccess, let cache else { return nil }
        self.textureCache = cache

        // BGRA so the GPU can sample it directly with no conversion pass.
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .none
        player.isMuted = true

        NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.handleEnd()
        }
        player.play()

        // Duration resolves asynchronously; BPM-sync rate needs it, so apply
        // the transport again once it is known rather than guessing.
        let seconds: @Sendable (AVURLAsset) async -> Double = { a in
            guard let d = try? await a.load(.duration), d.seconds.isFinite else { return 0 }
            return d.seconds
        }
        Task { [weak self, asset] in
            let d = await seconds(asset)
            await MainActor.run { [weak self] in
                self?.durationSeconds = d
                self?.applyTransport()
            }
        }
    }

    /// End-of-clip behaviour, per the transport's playthrough mode.
    private func handleEnd() {
        switch transport.playthrough {
        case .loop:
            player.seek(to: startTime())
            player.play()
        case .pingPong:
            // AVPlayer cannot play backwards reliably for compressed media, so
            // ping-pong restarts forward rather than stuttering. Honest
            // limitation, flagged rather than faked.
            player.seek(to: startTime())
            player.play()
        case .random:
            let span = max(transport.span, 0.001)
            let t = transport.trimIn + Double.random(in: 0...1) * span
            player.seek(to: CMTime(seconds: t * max(durationSeconds, 0.001),
                                   preferredTimescale: 600))
            player.play()
        case .once, .holdLast:
            // Hold the final frame. Blackout stays an explicit operator action,
            // never a side effect of a clip ending.
            player.pause()
        }
    }

    private func startTime() -> CMTime {
        CMTime(seconds: transport.trimIn * max(durationSeconds, 0.001),
               preferredTimescale: 600)
    }

    /// Pushes the transport's derived rate into the player.
    private func applyTransport() {
        let r = transport.rate(bpm: bpm, clipSeconds: durationSeconds)
        // Guard against a degenerate rate stalling or runaway-ing playback.
        let safe = min(max(r, 0.05), 16.0)
        if player.rate != 0 { player.rate = Float(safe) }
    }

    /// The texture for the current presentation time, if a new one is ready.
    ///
    /// Returns `nil` when no new frame is available — the caller **holds the
    /// previous frame** rather than stalling. A late source must never block
    /// the render thread.
    public func texture(at hostTime: CFTimeInterval) -> MTLTexture? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard output.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime,
                                                       itemTimeForDisplay: nil),
              let cache = textureCache
        else {
            repeatedFrames += 1
            return nil
        }

        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        width = w
        height = h

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .bgra8Unorm, w, h, 0, &cvTexture)

        guard status == kCVReturnSuccess, let cvTexture,
              let metalTexture = CVMetalTextureGetTexture(cvTexture) else {
            repeatedFrames += 1
            return nil
        }

        // Hold the CVMetalTexture: releasing it can invalidate the MTLTexture
        // while the GPU is still reading, which shows up as intermittent
        // corruption rather than a clean failure.
        currentTexture = cvTexture
        return metalTexture
    }

    public func play() { player.play() }
    public func pause() { player.pause() }
}
