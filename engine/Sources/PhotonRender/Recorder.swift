// Recording program output to disk.
//
// Encodes with VideoToolbox through `AVAssetWriter`, fed from the composited
// texture. Used for capturing a set, and for producing evidence when something
// goes wrong on site and nobody can reproduce it afterwards.
//
// ## Two rules, both learned from how this fails in practice
//
// **Recording must never stall the render thread.** Frames are handed over and
// the encoder keeps up or drops. A recorder that applies backpressure to the
// renderer turns a disk hiccup into dropped frames on the *projector* — trading
// an invisible problem for a visible one.
//
// **Overruns are surfaced, not swallowed.** If frames are dropped the operator
// is told. A recording that is quietly missing a third of its frames is worse
// than no recording, because it is discovered later, when the show is over.

import AVFoundation
import Foundation
import Metal

/// Outcome of a recording session.
public struct RecordingSummary: Sendable {
    public var url: URL
    public var framesWritten: Int
    /// Frames handed over while the encoder was not ready. **Not** a dropped
    /// program frame — the show was unaffected; the file is short.
    public var framesDropped: Int
    public var duration: Double

    public var isClean: Bool { framesDropped == 0 }
}

/// Encodes composited frames to a file.
public final class Recorder: @unchecked Sendable {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var pixelBufferPool: CVPixelBufferPool?

    private let width: Int
    private let height: Int
    private let fps: Int
    private var frameIndex = 0
    private var dropped = 0
    private var started = false

    /// Operator-facing status.
    public private(set) var status: String = "idle"
    public var isRecording: Bool { started }
    /// Frames the encoder could not accept. Surfaced, never swallowed.
    public var droppedFrames: Int { dropped }

    public init(width: Int, height: Int, fps: Int = 60) {
        // Encoders want even dimensions; an odd one fails late and obscurely.
        self.width = max(2, width - (width % 2))
        self.height = max(2, height - (height % 2))
        self.fps = max(1, fps)
    }

    /// Begins recording to `url`, replacing any existing file.
    @discardableResult
    public func start(to url: URL) -> Bool {
        guard !started else { return true }
        try? FileManager.default.removeItem(at: url)

        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: width * height * 8,
                    AVVideoMaxKeyFrameIntervalKey: fps * 2,
                ],
            ]
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            i.expectsMediaDataInRealTime = true

            let a = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: i,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferMetalCompatibilityKey as String: true,
                ])

            guard w.canAdd(i) else { status = "writer rejected input"; return false }
            w.add(i)
            guard w.startWriting() else {
                status = "startWriting failed: \(w.error?.localizedDescription ?? "unknown")"
                return false
            }
            w.startSession(atSourceTime: .zero)

            writer = w
            input = i
            adaptor = a
            frameIndex = 0
            dropped = 0
            started = true
            status = "recording"
            return true
        } catch {
            status = "could not create writer: \(error.localizedDescription)"
            return false
        }
    }

    /// Appends one frame from a readable texture.
    ///
    /// **Never blocks.** The frame is copied into a pooled buffer and handed to
    /// a bounded queue; a background task drains it into the encoder, waiting
    /// for readiness there rather than on the caller's thread.
    ///
    /// Returns false only when the queue is full, i.e. the encoder has fallen
    /// genuinely behind. That costs a frame in the *file*, never a frame on the
    /// projector — the whole point of the bound.
    @discardableResult
    public func append(texture: MTLTexture) -> Bool {
        guard started, let adaptor else { return false }
        guard queueDepth < Self.maxQueueDepth else {
            dropped += 1
            return false
        }
        guard let pool = adaptor.pixelBufferPool else { dropped += 1; return false }

        var maybeBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybeBuffer) == kCVReturnSuccess,
              let buffer = maybeBuffer else { dropped += 1; return false }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { dropped += 1; return false }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let copyW = min(width, texture.width)
        let copyH = min(height, texture.height)
        texture.getBytes(base, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, copyW, copyH), mipmapLevel: 0)

        enqueue(buffer)
        return true
    }

    /// Bounded so a stalled encoder cannot grow memory without limit during a
    /// show. Eight frames is ~130 ms at 60fps — enough to ride out a disk
    /// hiccup, short enough that a real stall is reported rather than hidden.
    static let maxQueueDepth = 8

    private let queueLock = NSLock()
    private var pendingBuffers: [CVPixelBuffer] = []
    private var draining = false

    private var queueDepth: Int { queueLock.withLock { pendingBuffers.count } }

    private func enqueue(_ buffer: CVPixelBuffer) {
        queueLock.withLock { pendingBuffers.append(buffer) }
        startDrainIfNeeded()
    }

    private func startDrainIfNeeded() {
        queueLock.withLock {
            guard !draining else { return }
            draining = true
        }
        // `.userInitiated`, not `.utility`: recording is something the operator
        // asked for and it is time-sensitive — a starved drain fills the queue
        // and the file quietly comes up short. It stays *below* the render
        // thread, which is the constraint that actually matters: the show must
        // never wait on the encoder.
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while true {
            let next: CVPixelBuffer? = queueLock.withLock {
                if pendingBuffers.isEmpty { draining = false; return nil }
                return pendingBuffers.removeFirst()
            }
            guard let buffer = next, let adaptor, let input else { return }

            // Wait for the encoder HERE, off the render thread.
            var spins = 0
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(nanoseconds: 1_000_000)
                spins += 1
                if spins > 2_000 { dropped += 1; break }   // ~2s: genuinely stuck
            }
            guard input.isReadyForMoreMediaData else { continue }

            let time = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps))
            if adaptor.append(buffer, withPresentationTime: time) {
                frameIndex += 1
            } else {
                dropped += 1
            }
        }
    }

    /// Waits for the queue to empty. Used before finishing.
    private func flush() async {
        var spins = 0
        while queueDepth > 0, spins < 5_000 {
            try? await Task.sleep(nanoseconds: 1_000_000)
            spins += 1
        }
    }

    /// Finishes and finalises the file.
    public func stop() async -> RecordingSummary? {
        guard started, let writer, let input else { return nil }
        started = false
        // Drain what is still queued before finalising, or the tail of the
        // recording is silently missing.
        await flush()
        input.markAsFinished()
        await writer.finishWriting()

        let summary = RecordingSummary(
            url: writer.outputURL,
            framesWritten: frameIndex,
            framesDropped: dropped,
            duration: Double(frameIndex) / Double(fps))

        // State the truth plainly. A file quietly missing a third of its frames
        // is worse than no file, because it is found out later.
        status = summary.isClean
            ? "wrote \(frameIndex) frames"
            : "wrote \(frameIndex) frames, DROPPED \(dropped)"

        self.writer = nil
        self.input = nil
        self.adaptor = nil
        return summary
    }
}
