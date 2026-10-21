import AppKit
import Testing
@testable import ClipShelf

struct FileThumbnailTests {
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
