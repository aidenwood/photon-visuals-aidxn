// Poster frames for the clip grid.
//
// A grid of 128 clip slots does NOT imply 128 video decoders. Idle clips show a
// cheap cached poster frame; only *playing* clips cost a live source. That
// distinction is what keeps a dense grid affordable, and it is why this exists
// separately from `VideoSource`.
//
// Scheduling, per `docs/thread-qos-map.md`:
//  - Generation runs at **`.utility`**, deliberately below playback. A grid
//    scrolling must never steal cycles from program output.
//  - Results are cached **on disk** as well as in memory, so a relaunch during
//    a gig is instant rather than re-decoding the whole library.
//  - Requests are cancellable and de-duplicated: scrolling a long library
//    otherwise queues hundreds of decodes for frames nobody will look at.

import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Generates and caches poster frames for media files.
public actor ThumbnailCache {
    /// Where on disk generated thumbnails live.
    private let directory: URL
    /// Longest edge, in pixels. Grid cells are small; decoding full frames for
    /// them is pure waste.
    private let maxPixel: CGFloat

    private var memory: [URL: CGImage] = [:]
    private var inFlight: [URL: Task<CGImage?, Never>] = [:]

    /// Thumbnails generated this session, for telemetry.
    public private(set) var generated = 0
    /// Requests served without decoding anything.
    public private(set) var hits = 0

    public init(directory: URL, maxPixel: CGFloat = 320) {
        self.directory = directory
        self.maxPixel = maxPixel
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Default location: a hidden folder beside the media.
    public static func beside(_ mediaDirectory: URL) -> ThumbnailCache {
        ThumbnailCache(directory: mediaDirectory.appendingPathComponent(".thumbs"))
    }

    /// A poster frame for `url`, decoding only if necessary.
    ///
    /// Concurrent calls for the same URL share one decode rather than racing —
    /// a scrolling grid asks for the same item repeatedly.
    public func thumbnail(for url: URL) async -> CGImage? {
        if let cached = memory[url] {
            hits += 1
            return cached
        }
        if let existing = inFlight[url] {
            return await existing.value
        }
        if let onDisk = loadFromDisk(url) {
            memory[url] = onDisk
            hits += 1
            return onDisk
        }

        let task = Task(priority: .utility) { [maxPixel] in
            await Self.generate(url: url, maxPixel: maxPixel)
        }
        inFlight[url] = task
        let image = await task.value
        inFlight[url] = nil

        if let image {
            memory[url] = image
            generated += 1
            saveToDisk(image, for: url)
        }
        return image
    }

    /// Drops in-memory images but keeps the disk cache.
    ///
    /// Called under memory pressure: a thumbnail is always re-derivable, so it
    /// is the first thing that should go — never program state.
    public func purgeMemory() {
        memory.removeAll(keepingCapacity: true)
    }

    /// Cancels a pending request, e.g. when a cell scrolls out of view.
    public func cancel(_ url: URL) {
        inFlight[url]?.cancel()
        inFlight[url] = nil
    }

    // MARK: - Generation

    private static func generate(url: URL, maxPixel: CGFloat) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        // A frame at exactly t=0 is often black (fades, leaders), which makes a
        // library look broken. Sample slightly in.
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2.0, preferredTimescale: 600)

        let target = CMTime(seconds: 1.0, preferredTimescale: 600)
        do {
            let (image, _) = try await gen.image(at: target)
            return image
        } catch {
            // A library can legitimately contain files we cannot decode. That
            // must degrade to "no thumbnail", never to a crash or an error
            // dialog mid-show.
            return nil
        }
    }

    // MARK: - Disk cache

    private func cacheURL(for url: URL) -> URL {
        // Hash the path so sibling files with the same name cannot collide, and
        // include size so changing `maxPixel` invalidates cleanly.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in url.path.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x1000_0000_01b3
        }
        return directory.appendingPathComponent(
            String(format: "%016llx-%d.jpg", hash, Int(maxPixel)))
    }

    private func loadFromDisk(_ url: URL) -> CGImage? {
        let path = cacheURL(for: url)
        guard let src = CGImageSourceCreateWithURL(path as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        // A stale thumbnail is worse than none: the operator would launch a
        // clip that looks nothing like its tile.
        if let mediaDate = try? FileManager.default
            .attributesOfItem(atPath: url.path)[.modificationDate] as? Date,
           let thumbDate = try? FileManager.default
            .attributesOfItem(atPath: path.path)[.modificationDate] as? Date,
           mediaDate > thumbDate {
            return nil
        }
        return img
    }

    private func saveToDisk(_ image: CGImage, for url: URL) {
        let path = cacheURL(for: url)
        guard let dest = CGImageDestinationCreateWithURL(
            path as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.8,
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
