// What a layer pulls frames from, whatever the codec underneath.
//
// Two implementations exist and they are not variations on each other:
//
//   VideoSource       H.264/HEVC/ProRes/MJPEG via VideoToolbox, delivered as an
//                     IOSurface-backed CVPixelBuffer and wrapped as a texture
//                     with zero copy. The pixels never touch the CPU.
//
//   BlockVideoSource  DXV. The frames are ALREADY GPU block-compressed, so the
//                     CPU undoes only the LZ layer and uploads BC1/BC3 blocks
//                     to a compressed texture. Expanding them to RGBA — which
//                     is what FFmpeg's DXV decoder does — would cost 4x the
//                     bandwidth, 8x the texture memory, and throw away the one
//                     property that makes DXV worth playing.
//
// The engine holds the protocol, so a layer does not know or care which it got.

import AVFoundation
import Metal
import simd

/// A source of per-frame textures for one layer.
public protocol FrameSource: AnyObject {
    /// The file this source plays. Lets the engine keep a source alive across a
    /// layer-stack rebuild when the clip has not changed — reordering layers
    /// must not restart video.
    var url: URL { get }

    /// How this clip plays. Takes effect on the next frame.
    var transport: ClipTransport { get set }

    /// Tempo, for BPM-synced clips. Set by the engine from the clock.
    var bpm: Double { get set }

    /// Frames the source could not supply in time. A repeat means the *source*
    /// was late — distinct from us missing a deadline, and counted separately.
    var repeatedFrames: Int { get }

    /// Fraction of the texture that is visible picture.
    ///
    /// `(1, 1)` for everything except block-compressed formats, whose textures
    /// are padded up to whole blocks. A sampler that ignored this would show a
    /// strip of garbage down the right-hand edge of any clip whose width is not
    /// a multiple of 16.
    var textureScale: SIMD2<Float> { get }

    /// Whether the texture's RGB is multiplied by its alpha and the sampler
    /// must divide it back out. True for DXV's DXT5.
    var isPremultiplied: Bool { get }

    /// Whether the source has no alpha channel and the sampled alpha must be
    /// ignored.
    ///
    /// Metal has no `bc1_rgb`, only `bc1_rgba`, and in a BC1 block with
    /// `c0 <= c1` the hardware reads palette index 3 as **transparent**. DXV's
    /// DXT1 carries no alpha, and FFmpeg decodes that same texel as opaque
    /// black. Left alone the two disagree, and the symptom is a DXT1 layer
    /// going see-through in patches once something is underneath it.
    var isOpaque: Bool { get }

    /// The texture for this host time, or `nil` if no new frame is ready.
    ///
    /// `nil` means **hold the previous frame**, never stall. A late source must
    /// not block the render thread.
    func texture(at hostTime: CFTimeInterval) -> MTLTexture?

    func play()
    func pause()
}

public extension FrameSource {
    var textureScale: SIMD2<Float> { SIMD2(1, 1) }
    var isPremultiplied: Bool { false }
    var isOpaque: Bool { false }
}

// MARK: - Choosing one

/// What the container says about a clip, loaded once per file.
public struct MediaProbe {
    let asset: AVURLAsset
    let track: AVAssetTrack
    /// Codec four-character code, e.g. `DXD3`, `avc1`, `jpeg`.
    public let subType: FourCharCode
    /// Visible frame size.
    public let width: Int
    /// Visible frame size.
    public let height: Int
    /// Track duration in seconds.
    public let duration: Double
    /// Declared frame rate, or 0 if the container does not say.
    public let nominalFrameRate: Double

    /// Resolume's DXV tags. `DXDI` is DXV1, `DXD3` is DXV3, `DXDA` is DXV4.
    public var isDXV: Bool {
        subType == fourCC("DXDI") || subType == fourCC("DXD3") || subType == fourCC("DXDA")
    }
}

public func fourCC(_ s: String) -> FourCharCode {
    var v: FourCharCode = 0
    for b in s.utf8.prefix(4) { v = (v << 8) | FourCharCode(b) }
    return v
}

/// Renders a four-character code for an operator-facing message.
///
/// Worth having because `DXDI` and `DXD3` refuse for different reasons — DXV1
/// versus a YCoCg variant — and "re-encode this clip" is a different amount of
/// work depending which.
public func fourCCString(_ v: FourCharCode) -> String {
    String(bytes: [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                   UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)], encoding: .ascii) ?? "????"
}

/// Loads a clip's container metadata.
///
/// Blocking, deliberately: the engine has to know whether a clip is DXV *before*
/// it can build the right source, and a source that announced its own codec
/// asynchronously would mean the first frames of a launched clip played through
/// the wrong path. The wait is bounded, happens once per clip load, and sits
/// alongside the file open that was going to happen anyway.
///
/// The load runs on a detached task, never on the caller's executor, so waiting
/// here cannot deadlock the thread that is waiting.
public func probeMedia(url: URL, timeout: TimeInterval = 5.0) -> MediaProbe? {
    let asset = AVURLAsset(url: url)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: MediaProbe?

    Task.detached {
        defer { sem.signal() }
        guard let tracks = try? await asset.loadTracks(withMediaType: .video),
              let track = tracks.first,
              let desc = try? await track.load(.formatDescriptions).first else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(desc)
        let range = (try? await track.load(.timeRange)) ?? .zero
        let fps = (try? await track.load(.nominalFrameRate)) ?? 0
        result = MediaProbe(
            asset: asset,
            track: track,
            subType: CMFormatDescriptionGetMediaSubType(desc),
            width: Int(dims.width),
            height: Int(dims.height),
            duration: CMTimeGetSeconds(range.duration),
            nominalFrameRate: Double(fps))
    }

    guard sem.wait(timeout: .now() + timeout) == .success else { return nil }
    return result
}

/// Builds the right source for a clip.
///
/// DXV goes to the block path; everything else to AVFoundation. A DXV file the
/// core cannot decompress (`YCG6`/`YG10`, or DXV1) fails here with a reason
/// rather than falling back to AVFoundation — AVFoundation cannot decode DXV
/// either, so a "fallback" would only produce a layer that is silently black.
public func makeFrameSource(url: URL, device: MTLDevice) -> FrameSource? {
    guard let probe = probeMedia(url: url) else {
        // No video track, or the container would not open. AVFoundation still
        // gets a go: it handles some files whose tracks load lazily.
        return VideoSource(url: url, device: device)
    }
    if probe.isDXV {
        return BlockVideoSource(probe: probe, url: url, device: device)
    }
    return VideoSource(url: url, device: device)
}
