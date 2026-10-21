import AppKit
import SwiftUI
import QuickLookThumbnailing

actor FileThumbnailCache {
    static let shared = FileThumbnailCache()
    struct Key: Hashable, Sendable {
        let url: URL
        let modified: Date?
        let bytes: Int?
        let scale: CGFloat
        var identifier: NSString { "\(url.absoluteString)|\(modified?.timeIntervalSinceReferenceDate ?? 0)|\(bytes ?? 0)|\(scale)" as NSString }
    }
    final class Entry: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }
    private let images = NSCache<NSString, Entry>()
    init() {
        images.countLimit = 128
        images.totalCostLimit = 32 * 1024 * 1024
    }
    // File metadata is read on this actor, never during SwiftUI's main-thread layout.
    func key(for urls: [URL], scale: CGFloat) -> Key? {
        for originalURL in urls where originalURL.isFileURL {
            var url = originalURL
            url.removeAllCachedResourceValues()
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            return Key(url: url, modified: values.contentModificationDate, bytes: values.fileSize, scale: scale)
        }
        return nil
    }
    func entry(for key: Key) -> Entry? { images.object(forKey: key.identifier) }
    func store(_ image: NSImage?, for key: Key) {
        let pixels = Int(224 * key.scale) * Int(116 * key.scale)
        images.setObject(Entry(image), forKey: key.identifier, cost: pixels * 4)
    }
}

struct FileCardThumbnail: NSViewRepresentable {
    let urls: [URL]
    let refreshID: UUID
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(systemSymbolName: "doc", accessibilityDescription: L("文件"))
        return view
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        let coordinator = context.coordinator
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard coordinator.urls != urls || coordinator.refreshID != refreshID || coordinator.scale != scale else { return }
        coordinator.cancel()
        coordinator.urls = urls; coordinator.refreshID = refreshID; coordinator.scale = scale
        view.image = NSImage(systemSymbolName: "doc", accessibilityDescription: L("文件"))
        let generation = coordinator.generation
        coordinator.task = Task { @MainActor [weak view, weak coordinator] in
            guard let key = await FileThumbnailCache.shared.key(for: urls, scale: scale), !Task.isCancelled,
                  let coordinator, let view, coordinator.generation == generation else { return }
            let cached = await FileThumbnailCache.shared.entry(for: key)
            guard !Task.isCancelled, coordinator.generation == generation else { return }
            if let cached {
                if let image = cached.image { view.image = image }
                return
            }
            let request = QLThumbnailGenerator.Request(fileAt: key.url, size: CGSize(width: 224, height: 116), scale: scale, representationTypes: [.thumbnail, .icon])
            coordinator.request = request
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak view, weak coordinator] thumbnail, _ in
                let image = thumbnail?.nsImage
                Task { @MainActor in
                    guard let coordinator, coordinator.generation == generation else { return }
                    coordinator.request = nil
                    if let image { view?.image = image }
                    await FileThumbnailCache.shared.store(image, for: key)
                }
            }
        }
    }
    static func dismantleNSView(_ view: NSImageView, coordinator: Coordinator) { coordinator.cancel() }
    @MainActor final class Coordinator {
        var urls: [URL] = []
        var refreshID: UUID?
        var scale: CGFloat = 0
        var generation = UUID()
        var task: Task<Void, Never>?
        var request: QLThumbnailGenerator.Request?
        func cancel() {
            generation = UUID()
            task?.cancel(); task = nil
            if let request { QLThumbnailGenerator.shared.cancel(request) }
            request = nil
        }
    }
}
