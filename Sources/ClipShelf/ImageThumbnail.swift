import AppKit
import SwiftUI
import ImageIO
import ClipboardCore

actor ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    private let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    func image(for clip: Clip) -> NSImage? {
        let key = clip.fingerprint as NSString
        if let cached = images.object(forKey: key) { return cached }
        guard !Task.isCancelled,
              let data = clip.items.lazy.flatMap({ $0 }).first(where: { $0.type == "public.png" || $0.type == "public.tiff" })?.data,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary), !Task.isCancelled else { return nil }
        let image = NSImage(cgImage: thumbnail, size: .zero)
        images.setObject(image, forKey: key, cost: thumbnail.bytesPerRow * thumbnail.height)
        return image
    }
}

struct ClipImageThumbnail: View {
    let clip: Clip
    var highlights: [CGRect] = []
    @StateObject private var state = ImageThumbnailState()
    var body: some View {
        Group {
            if let image = state.image { HighlightedClipImage(image: image, highlights: highlights) }
            else { Image(systemName: "photo").foregroundStyle(.secondary).accessibilityLabel(L("图片")) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: clip.fingerprint) {
            state.image = nil
            let thumbnail = await ImageThumbnailCache.shared.image(for: clip)
            guard !Task.isCancelled else { return }
            state.image = thumbnail
        }
        .onDisappear { state.image = nil }
    }
}

private final class ImageThumbnailState: ObservableObject {
    @Published var image: NSImage?
}
