import Foundation
import Testing
import AppKit
@testable import ClipShelf
import ClipboardCore

struct ClipboardIntegrationTests {
    @Test @MainActor
    func imageFileClassificationMigratesAndKeepsClipboardFormats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = NSPasteboard(name: .init("ClipShelf-image-classification-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let url = directory.appendingPathComponent("history.plist")
        let image = Data([1, 2, 3])
        let file = "file:///tmp/example.png"
        let items = [[Representation(type: "public.file-url", data: Data(file.utf8)), Representation(type: "public.png", data: image)]]
        var old = Clip(kind: .files, text: "example.png", sourceName: "Finder", sourceBundle: "com.apple.finder",
                       items: items, identity: Data(file.utf8))
        old.title = "保留名称"
        var history = History(clips: [old])
        let collection = try history.addBoard(name: "收藏", color: 1)
        history.addToBoard(clipID: old.id, boardID: collection)
        try history.save(to: url)
        let preferences = isolatedPreferences(); preferences.retention = .forever
        let service = ImageTextService(cacheURL: directory.appendingPathComponent("ocr.sqlite"), recognize: { _ in "中文搜索" })
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: preferences, imageTextService: service)
        await model.waitForImageText()
        let corrected = try #require(model.history.clips.first)
        #expect(corrected.kind == .image && corrected.id == old.id)
        #expect(corrected.title == old.title && corrected.copiedAt == old.copiedAt)
        #expect(corrected.items == old.items && corrected.text == old.text)
        #expect(model.history.boards.map(\.id) == history.boards.map(\.id))
        #expect(model.history.boards.first(where: { $0.id == collection })?.clipIDs == [old.id])
        for query in ["中文", "zhongwen", "zw"] {
            model.query = query; await model.waitForSearch()
            #expect(model.visible.map(\.id) == [old.id])
        }
        let item = NSPasteboardItem(); item.setString(file, forType: .fileURL); item.setData(image, forType: .png)
        board.clearContents(); #expect(board.writeObjects([item]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 1 && model.history.clips.first?.id == old.id)
        #expect(model.copy(corrected))
        #expect(board.string(forType: .fileURL) == file && board.data(forType: .png) == image)
        for path in ["file:///tmp/example.pdf", "file:///tmp/folder.png/"] {
            let fileItem = NSPasteboardItem(); fileItem.setString(path, forType: .fileURL); fileItem.setData(image, forType: .png)
            board.clearContents(); #expect(board.writeObjects([fileItem]))
            await model.capture(expectedChange: board.changeCount, source: nil)
            #expect(model.history.clips.first?.kind == .files)
        }
        let second = NSPasteboardItem(); second.setString("file:///tmp/another.png", forType: .fileURL)
        let first = NSPasteboardItem(); first.setString(file, forType: .fileURL); first.setData(image, forType: .png)
        board.clearContents(); #expect(board.writeObjects([first, second]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.kind == .files)
        #expect(await model.finishPendingStorage())
        #expect(try History.load(from: url).clips == model.history.clips)
        var restored = try History.load(from: url)
        #expect(try !restored.reclassifyImageFiles())
    }

    @Test @MainActor
    func failedBackgroundSaveBlocksQuitAndRetriesWithoutLosingCards() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("blocked")
        try Data([0]).write(to: blocked)
        let board = NSPasteboard(name: .init("ClipShelf-storage-failure-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let url = blocked.appendingPathComponent("history.plist")
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: isolatedPreferences())
        defer { _ = model.flushStorage() }
        board.setString("retained in memory", forType: .string)
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(!(await model.finishPendingStorage()))
        #expect(model.storageFailed && model.message != nil)
        #expect(model.history.clips.count == 1)
        try FileManager.default.removeItem(at: blocked)
        board.clearContents(); board.setString("retry", forType: .string)
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(await model.finishPendingStorage())
        #expect(!model.storageFailed)
        #expect(model.history.clips.count == 2)
        #expect(try History.load(from: url).clips == model.history.clips)
    }

    @Test @MainActor
    func copyingPromotesCardsAndPersistsTheirOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-promote-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: isolatedPreferences())
        defer { _ = model.flushStorage() }
        for text in ["第一项", "第二项", "第三项"] {
            board.clearContents(); board.setString(text, forType: .string)
            await model.capture(expectedChange: board.changeCount, source: nil)
        }
        let first = try #require(model.history.clips.first(where: { $0.text == "第一项" }))
        let second = try #require(model.history.clips.first(where: { $0.text == "第二项" }))
        let boardID = try model.history.addBoard(name: "测试", color: 0)
        model.history.addToBoard(clipID: first.id, boardID: boardID)
        model.history.addToBoard(clipID: second.id, boardID: boardID)
        #expect(model.copy(first))
        #expect(model.visible.map(\.text) == ["第一项", "第三项", "第二项"])
        #expect(model.history.clips.first?.id == first.id)
        model.selectedBoardID = boardID
        #expect(model.visible.map(\.id) == [first.id, second.id])
        model.selectedBoardID = nil
        #expect(model.copy([second, first], plainText: true))
        #expect(model.visible.map(\.text) == ["第二项", "第一项", "第三项"])
        #expect(board.string(forType: .string) == "第二项\n第一项")
        model.poll()
        #expect(model.history.clips.count == 3)
        #expect(model.flushStorage())
        #expect(try History.load(from: url).clips == model.history.clips)
    }

    @Test @MainActor
    func stackWritesNextItemAndDoesNotRecaptureItsOwnPaste() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-stack-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        defer { _ = model.flushStorage() }
        model.startStack(includeSelection: false)
        for text in ["第一项", "第二项"] {
            board.clearContents(); board.setString(text, forType: .string)
            await model.capture(expectedChange: board.changeCount, source: nil)
        }
        #expect(model.stackClips.map(\.text) == ["第一项", "第二项"])
        #expect(model.prepareStackPaste())
        #expect(board.string(forType: .string) == "第一项")
        model.poll()
        #expect(model.stackClips.map(\.text) == ["第二项"])
        #expect(model.prepareStackPaste())
        #expect(board.string(forType: .string) == "第二项")
        #expect(!model.prepareStackPaste())
        #expect(board.string(forType: .string) == "第二项")
        #expect(model.history.clips.count == 2)
        board.clearContents(); board.setString("尚未轮询的第三项", forType: .string)
        #expect(model.prepareStackPaste())
        #expect(board.string(forType: .string) == "尚未轮询的第三项")
        #expect(model.stackIDs.isEmpty)
        #expect(model.history.clips.count == 3)
    }

    @Test @MainActor
    func captureDedupSearchPersistenceAndMultiformatRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: isolatedPreferences())
        defer { _ = model.flushStorage() }
        let rich = Data("{\\rtf1 hello}".utf8)
        let item = NSPasteboardItem()
        item.setString("测试剪贴板 hello", forType: .string); item.setData(rich, forType: .rtf)
        board.clearContents(); #expect(board.writeObjects([item]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 1)
        let originalID = try #require(model.history.clips.first?.id)
        let second = NSPasteboardItem(); second.setString("另一条记录", forType: .string)
        board.clearContents(); #expect(board.writeObjects([second]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        let duplicate = NSPasteboardItem()
        duplicate.setString("测试剪贴板 hello", forType: .string); duplicate.setData(rich, forType: .rtf)
        board.clearContents(); #expect(board.writeObjects([duplicate]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 2)
        #expect(model.history.clips.first?.id == originalID)
        model.query = "测试 hello"
        await model.waitForSearch()
        #expect(model.visible.count == 1, "query=\(model.query), pending=\(model.searchPending), applied=\(model.hasSearchResults), matches=\(model.searchMatches), error=\(model.searchError ?? "none")")
        let clip = try #require(model.visible.first)
        model.copy(clip)
        #expect(board.string(forType: .string) == "测试剪贴板 hello")
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == rich)
        model.poll()
        #expect(model.history.clips.count == 2)
        #expect(model.flushStorage())
        #expect(try History.load(from: url).clips == model.history.clips)
    }

    @Test @MainActor
    func imageFilesAndConfidentialExclusion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        defer { _ = model.flushStorage() }
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pixels.setColor(.systemGreen, atX: 0, y: 0)
        let png = try #require(pixels.representation(using: .png, properties: [:]))
        let image = NSPasteboardItem(); image.setData(png, forType: .png)
        board.clearContents(); #expect(board.writeObjects([image]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.kind == .image)
        let file = NSPasteboardItem(); file.setString("file:///tmp/clipshelf-example.txt", forType: .fileURL)
        board.clearContents(); #expect(board.writeObjects([file]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.kind == .files)
        #expect(model.history.clips.first?.text == "clipshelf-example.txt")
        let secret = NSPasteboardItem(); secret.setString("test secret", forType: .string)
        secret.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); #expect(board.writeObjects([secret]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 2)
        model.filter = .image
        #expect(model.visible.count == 1)
        let largePayload = Data(repeating: 7, count: 6 * 1024 * 1024)
        let large = NSPasteboardItem(); large.setData(largePayload, forType: .png)
        board.clearContents(); #expect(board.writeObjects([large]))
        await model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.byteCount == largePayload.count)
        let largeClip = try #require(model.history.clips.first)
        #expect(model.copy(largeClip))
        #expect(board.data(forType: .png) == largePayload)
        #expect(await model.finishPendingStorage())
        #expect(try History.load(from: directory.appendingPathComponent("history.plist")).clips == model.history.clips)
    }
}
