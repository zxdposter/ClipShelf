import Foundation
import Testing
import AppKit
@testable import ClipShelf
import ClipboardCore

struct ClipboardIntegrationTests {
    @Test @MainActor
    func stackWritesNextItemAndDoesNotRecaptureItsOwnPaste() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-stack-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        model.startStack(includeSelection: false)
        for text in ["第一项", "第二项"] {
            board.clearContents(); board.setString(text, forType: .string)
            model.capture(expectedChange: board.changeCount, source: nil)
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
    }

    @Test @MainActor
    func captureDedupSearchPersistenceAndMultiformatRestore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.plist")
        let model = ClipboardModel(pasteboard: board, storageURL: url, preferences: isolatedPreferences())
        let rich = Data("{\\rtf1 hello}".utf8)
        let item = NSPasteboardItem()
        item.setString("测试剪贴板 hello", forType: .string); item.setData(rich, forType: .rtf)
        board.clearContents(); #expect(board.writeObjects([item]))
        model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 1)
        let originalID = try #require(model.history.clips.first?.id)
        let second = NSPasteboardItem(); second.setString("另一条记录", forType: .string)
        board.clearContents(); #expect(board.writeObjects([second]))
        model.capture(expectedChange: board.changeCount, source: nil)
        let duplicate = NSPasteboardItem()
        duplicate.setString("测试剪贴板 hello", forType: .string); duplicate.setData(rich, forType: .rtf)
        board.clearContents(); #expect(board.writeObjects([duplicate]))
        model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 2)
        #expect(model.history.clips.first?.id == originalID)
        model.query = "测试 hello"
        await model.waitForSearch()
        #expect(model.visible.count == 1)
        let clip = try #require(model.visible.first)
        model.copy(clip)
        #expect(board.string(forType: .string) == "测试剪贴板 hello")
        #expect(board.pasteboardItems?.first?.data(forType: .rtf) == rich)
        model.poll()
        #expect(model.history.clips.count == 2)
        #expect(try History.load(from: url).clips == model.history.clips)
    }

    @Test @MainActor
    func imageFilesAndConfidentialExclusion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard(name: .init("ClipShelf-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: directory) }
        let model = ClipboardModel(pasteboard: board, storageURL: directory.appendingPathComponent("history.plist"), preferences: isolatedPreferences())
        let pixels = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        pixels.setColor(.systemGreen, atX: 0, y: 0)
        let png = try #require(pixels.representation(using: .png, properties: [:]))
        let image = NSPasteboardItem(); image.setData(png, forType: .png)
        board.clearContents(); #expect(board.writeObjects([image]))
        model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.kind == .image)
        let file = NSPasteboardItem(); file.setString("file:///tmp/clipshelf-example.txt", forType: .fileURL)
        board.clearContents(); #expect(board.writeObjects([file]))
        model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.first?.kind == .files)
        #expect(model.history.clips.first?.text == "clipshelf-example.txt")
        let secret = NSPasteboardItem(); secret.setString("test secret", forType: .string)
        secret.setString("1", forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); #expect(board.writeObjects([secret]))
        model.capture(expectedChange: board.changeCount, source: nil)
        #expect(model.history.clips.count == 2)
        model.filter = .image
        #expect(model.visible.count == 1)
    }
}
