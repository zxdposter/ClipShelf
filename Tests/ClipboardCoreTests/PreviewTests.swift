import AppKit
import Testing
@testable import ClipShelf

struct PreviewTests {
    @Test @MainActor func spacePreviewUsesFocusedSelectedCardAndDoesNotCopy() throws {
        let model = ClipboardModel(demo: true, preferences: isolatedPreferences())
        model.resetSelection()
        let id = try #require(model.selectedID)
        model.togglePreview()
        #expect(model.previewID == id)
        #expect(model.copiedID == nil)
        model.togglePreview()
        #expect(model.previewID == nil)
        model.selection.selectAll(in: model.visible.map(\.id))
        model.togglePreview()
        #expect(model.previewID == id)
        model.resetSelection()
        #expect(model.previewID == nil)
        model.selection = .init()
        model.togglePreview()
        #expect(model.previewID == nil)
    }
    @Test @MainActor func appColorIgnoresNeutralAndTransparentPixels() throws {
        let icon = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill()
            NSColor.systemRed.setFill(); NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        let color = try #require(representativeColor(of: icon).usingColorSpace(.deviceRGB))
        #expect(color.redComponent > color.greenComponent * 2)
        #expect(color.redComponent > color.blueComponent * 2)
        let empty = NSImage(size: NSSize(width: 24, height: 24))
        #expect(representativeColor(of: empty) == .secondaryLabelColor)
    }
    @Test func textStatisticsPreserveLineBreaks() {
        #expect(previewStatistics("") == "0 个字符 · 0 单词 · 0 行")
        #expect(previewStatistics("hello world\nnext") == "16 个字符 · 3 单词 · 2 行")
    }
}
