import AppKit
import Testing
@testable import ClipShelf
@testable import ClipboardCore

struct ImageEditingTests {
    @Test func rotationChangesDimensionsAndRejectsInvalidImages() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let rotated = try ImageEditing.rotate(png, clockwise: true)
        let image = try #require(NSBitmapImageRep(data: rotated))
        #expect(image.pixelsWide == 2 && image.pixelsHigh == 3)
        let restored = try #require(NSBitmapImageRep(data: ImageEditing.rotate(rotated, clockwise: false)))
        #expect(restored.pixelsWide == 3 && restored.pixelsHigh == 2)
        #expect(throws: (any Error).self) { try ImageEditing.rotate(Data(), clockwise: true) }
    }
    @Test func imageEditPreservesIdentityTitleAndPinboard() throws {
        let clip = Clip(kind: .image, text: "image", sourceName: "Test", sourceBundle: "test", items: [[Representation(type: "public.png", data: Data([1]))]], identity: Data([1]))
        var history = History()
        try history.insert(clip); try history.rename(id: clip.id, title: "Test image")
        let board = try #require(history.boards.first)
        history.addToBoard(clipID: clip.id, boardID: board.id)
        try history.editImage(id: clip.id, png: Data([2]))
        #expect(history.clips.first?.id == clip.id)
        #expect(history.clips.first?.title == "Test image")
        #expect(history.clips.first?.items.first?.first?.data == Data([2]))
        #expect(history.boards.first?.clipIDs == [clip.id])
    }
}

extension ImageEditingTests {
    private func imageFixture() throws -> Clip {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        return Clip(kind: .image, text: "Fixture", sourceName: "Test", sourceBundle: "test", items: [[Representation(type: "public.png", data: png)]], identity: png)
    }
    @Test @MainActor func cancelledBackgroundWorkCannotModifyNewDraft() async throws {
        _ = NSApplication.shared
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let clip = try imageFixture()
        model.history = History(clips: [clip])
        model.beginImageEdit(clip)
        let draft = try #require(model.imageDraft)
        let task = try #require(model.removeImageBackground(processor: { _ in Data([9, 8, 7]) }))
        #expect(model.removingBackground)
        model.finishTextEdit()
        #expect(model.editingClipID == clip.id)
        model.closePreview()
        model.beginImageEdit(clip)
        await task.value
        #expect(model.imageDraft == draft)
        #expect(!model.removingBackground)
        #expect(model.editingClipID == clip.id)
        model.closePreview()
        #expect(model.previewID == nil && model.imageDraft == nil && model.imageOriginal == nil)
    }
    @Test @MainActor func failedBackgroundRemovalKeepsDraftAndHistory() async throws {
        _ = NSApplication.shared
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        let clip = try imageFixture()
        model.history = History(clips: [clip])
        model.beginImageEdit(clip)
        let draft = model.imageDraft
        let task = try #require(model.removeImageBackground(processor: { _ in throw CocoaError(.featureUnsupported) }))
        await task.value
        #expect(!model.removingBackground)
        #expect(model.imageDraft == draft)
        #expect(model.history.clips.first(where: { $0.id == clip.id }) == clip)
        #expect(model.message?.contains("无法移除背景") == true)
    }
}
