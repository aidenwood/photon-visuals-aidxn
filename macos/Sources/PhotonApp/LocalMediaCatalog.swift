import Foundation
import CoreGraphics
import PhotonRender
import PhotonUI

/// App-side catalogue for the existing local development media. The runtime adapter
/// can replace this provider without changing the grid's poster factory contract.
actor LocalMediaCatalog {
    private var urls: [String: URL] = [:]
    private var loadTask: Task<[MediaClip], Error>?
    private var cache: ThumbnailCache?
    private var pending: [String: Task<CGImage?, Never>] = [:]
    private var tail: Task<CGImage?, Never>?
    private var generations = 0

    func clips() async throws -> [MediaClip] {
        if let loadTask { return try await loadTask.value }
        let task = Task.detached(priority: .utility) { () throws -> [MediaClip] in
            let checkout = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("media-cache")
            let directory = Bundle.main.resourceURL?.appendingPathComponent("DevelopmentMedia") ?? checkout
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                .filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            return try urls.filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
                .map { url in
                    MediaClip(id: url.absoluteString, title: url.deletingPathExtension().lastPathComponent,
                        detail: url.pathExtension.uppercased() + " · Local media", artwork: .empty)
                }
        }
        loadTask = task
        do {
            let clips = try await task.value
            urls = Dictionary(uniqueKeysWithValues: clips.compactMap { clip in
                URL(string: clip.id).map { (clip.id, $0) }
            })
            return clips
        } catch {
            loadTask = nil
            throw PanelIssue(title: "Local media unavailable", message: "The local clip folder could not be read.")
        }
    }

    func poster(assetID: String) async -> CGImage? {
        _ = try? await clips()
        guard let url = urls[assetID] else { return nil }
        if let task = pending[assetID] { return await task.value }
        if cache == nil {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            cache = ThumbnailCache(directory: base.appendingPathComponent("com.aidxn.photon/posters"), maxPixel: 256)
        }
        guard let cache else { return nil }
        let previous = tail
        let purge = generations >= 128
        generations = purge ? 1 : generations + 1
        // Serial generation bounds decoder work. Cancelling one cell never cancels
        // a shared request used by another layer or the inspector.
        let task = Task(priority: .utility) {
            _ = await previous?.value
            if purge { await cache.purgeMemory() }
            return await cache.thumbnail(for: url)
        }
        pending[assetID] = task
        tail = task
        let image = await task.value
        pending[assetID] = nil
        return image
    }
}
