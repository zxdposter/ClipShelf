import AppKit
import SwiftUI
import Testing
@testable import ClipShelf
@testable import ClipboardCore

struct FileThumbnailTests {
    @Test @MainActor func oversizedThumbnailsStayInsideTheFileCard() async throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let clip = Clip(kind: .files, text: "example-file-with-a-long-name.session", sourceName: "Test", sourceBundle: "test", items: [], identity: Data("file".utf8))
        model.history = History(clips: [clip])
        model.resetSelection()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 352), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ShelfView(model: model, dismiss: {}, openSettings: {}, enableCapture: {}, paste: { _, _ in }))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(50))
        func imageViews(_ view: NSView) -> [NSImageView] {
            (view as? NSImageView).map { [$0] } ?? view.subviews.flatMap(imageViews)
        }
        let thumbnail = try #require(imageViews(host).first)
        for size in [NSSize(width: 1024, height: 2048), NSSize(width: 2048, height: 1024)] {
            thumbnail.image = NSImage(size: size)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let frame = thumbnail.convert(thumbnail.bounds, to: host)
            #expect(frame.width > 0 && frame.width <= 224)
            #expect(frame.height > 0 && frame.height <= 208)
            #expect(host.bounds.contains(frame))
        }
    }
    @Test func cacheInvalidatesWhenFileChangesAndSeparatesDisplayScales() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("预览.txt")
        let missing = directory.appendingPathComponent("missing.txt")
        try Data("first".utf8).write(to: file)
        let cache = FileThumbnailCache()
        let key = try #require(await cache.key(for: [missing, file], scale: 2))
        #expect(key.url == file)
        await cache.store(nil, for: key)
        #expect(await cache.entry(for: key) != nil)
        let retina = try #require(await cache.key(for: [file], scale: 1))
        #expect(await cache.entry(for: retina) == nil)
        try Data("longer new content".utf8).write(to: file)
        let changed = try #require(await cache.key(for: [file], scale: 2))
        #expect(changed != key)
        #expect(await cache.entry(for: changed) == nil)
        try FileManager.default.removeItem(at: file)
        #expect(await cache.key(for: [file], scale: 2) == nil)
        #expect(await cache.key(for: [URL(string: "https://example.com/file.pdf")!], scale: 2) == nil)
    }
}
